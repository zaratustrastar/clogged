import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";

let testDir: string;

beforeEach(async () => {
  vi.resetModules();
  // A fresh, real temporary directory per test - never the production
  // /var/lib/clog/uploads path. mkdtemp guarantees a unique, non-colliding
  // directory (same principle as the adapter's own filename generation).
  testDir = await mkdtemp(path.join(tmpdir(), "clog-upload-test-"));
  process.env.UPLOAD_DIR = testDir;
  process.env.UPLOAD_PUBLIC_BASE_URL = "https://clog.run/uploads";
});

afterEach(async () => {
  await rm(testDir, { recursive: true, force: true });
});

describe("filesystem storage adapter", () => {
  it("isFilesystemStorageConfigured is false when either env var is missing", async () => {
    delete process.env.UPLOAD_PUBLIC_BASE_URL;
    const { isFilesystemStorageConfigured } = await import("@/lib/storage/filesystem");
    expect(isFilesystemStorageConfigured()).toBe(false);
  });

  it("isFilesystemStorageConfigured is true when both env vars are set", async () => {
    const { isFilesystemStorageConfigured } = await import("@/lib/storage/filesystem");
    expect(isFilesystemStorageConfigured()).toBe(true);
  });

  it("rejects an unsupported MIME type and writes nothing to disk", async () => {
    const { uploadImage } = await import("@/lib/storage/filesystem");
    const result = await uploadImage(Buffer.from("not an image"), "application/pdf");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/Unsupported image type/);
    const files = await readdir(testDir).catch(() => []);
    expect(files.length).toBe(0);
  });

  it("rejects a file over the size limit and writes nothing to disk", async () => {
    const { uploadImage } = await import("@/lib/storage/filesystem");
    const oversized = Buffer.alloc(6 * 1024 * 1024); // 6 MB > 5 MB limit
    const result = await uploadImage(oversized, "image/png");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/too large/);
    const files = await readdir(testDir).catch(() => []);
    expect(files.length).toBe(0);
  });

  it("writes a real file to the real (temporary) directory and returns a correct public URL", async () => {
    const { uploadImage } = await import("@/lib/storage/filesystem");
    const content = Buffer.from("fake png bytes");
    const result = await uploadImage(content, "image/png");
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.key).toMatch(/^[0-9a-f-]+\.png$/);
      expect(result.url).toBe(`https://clog.run/uploads/${result.key}`);

      const files = await readdir(testDir);
      expect(files).toContain(result.key);

      const written = await import("node:fs/promises").then((fs) => fs.readFile(path.join(testDir, result.key)));
      expect(written.equals(content)).toBe(true);
    }
  });

  it("two uploads of identical bytes never collide on the same filename", async () => {
    const { uploadImage } = await import("@/lib/storage/filesystem");
    const bytes = Buffer.from("identical bytes");
    const first = await uploadImage(bytes, "image/jpeg");
    const second = await uploadImage(bytes, "image/jpeg");
    expect(first.ok && second.ok).toBe(true);
    if (first.ok && second.ok) {
      expect(first.key).not.toBe(second.key);
      const files = await readdir(testDir);
      expect(files.length).toBe(2);
    }
  });

  it("never leaves a temp file behind after a successful upload", async () => {
    const { uploadImage } = await import("@/lib/storage/filesystem");
    await uploadImage(Buffer.from("bytes"), "image/webp");
    const files = await readdir(testDir);
    expect(files.every((f) => !f.startsWith(".tmp-"))).toBe(true);
  });

  it("refuses to upload at all when storage is not configured", async () => {
    delete process.env.UPLOAD_DIR;
    const { uploadImage } = await import("@/lib/storage/filesystem");
    const result = await uploadImage(Buffer.from("bytes"), "image/png");
    expect(result.ok).toBe(false);
  });

  it("the original filename is never used as any part of the generated path (traversal resistance)", async () => {
    // The adapter's uploadImage signature doesn't even accept a filename
    // parameter - only bytes and a MIME type - so there is structurally no
    // path in the codebase where a user-supplied filename like
    // "../../etc/passwd" could reach the filesystem. This test documents
    // and locks in that structural guarantee.
    const { uploadImage } = await import("@/lib/storage/filesystem");
    const result = await uploadImage(Buffer.from("bytes"), "image/png");
    expect(result.ok).toBe(true);
    if (result.ok) {
      // The key is purely a UUID + extension - no slashes, no dots beyond
      // the extension separator, nothing resembling a path segment.
      expect(result.key.split("/").length).toBe(1);
      expect(result.key.split(".").length).toBe(2);
    }
  });
});

describe("isOwnUploadedImageUrl - gates POST /api/token-profile's imageUrl field", () => {
  it("accepts a real URL uploadImage() itself just produced - round-trip, not a hand-built lookalike", async () => {
    const { uploadImage, isOwnUploadedImageUrl } = await import("@/lib/storage/filesystem");
    const result = await uploadImage(Buffer.from("bytes"), "image/png");
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(isOwnUploadedImageUrl(result.url)).toBe(true);
    }
  });

  it("accepts a well-formed URL matching the real pattern for every allowed extension", async () => {
    const { isOwnUploadedImageUrl } = await import("@/lib/storage/filesystem");
    for (const ext of ["png", "jpg", "webp", "gif"]) {
      expect(isOwnUploadedImageUrl(`https://clog.run/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.${ext}`)).toBe(true);
    }
  });

  it("rejects an arbitrary external URL, even one that starts with the right domain elsewhere in the string", async () => {
    const { isOwnUploadedImageUrl } = await import("@/lib/storage/filesystem");
    expect(isOwnUploadedImageUrl("https://evil.example.com/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")).toBe(false);
    expect(isOwnUploadedImageUrl("https://clog.run.evil.com/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")).toBe(false);
  });

  it("rejects data:, javascript:, and protocol-relative URLs", async () => {
    const { isOwnUploadedImageUrl } = await import("@/lib/storage/filesystem");
    expect(isOwnUploadedImageUrl("data:image/png;base64,aGVsbG8=")).toBe(false);
    expect(isOwnUploadedImageUrl("javascript:alert(1)")).toBe(false);
    expect(isOwnUploadedImageUrl("//clog.run/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")).toBe(false);
  });

  it("rejects the right prefix with a malformed filename (not a real uploaded file's own shape)", async () => {
    const { isOwnUploadedImageUrl } = await import("@/lib/storage/filesystem");
    expect(isOwnUploadedImageUrl("https://clog.run/uploads/not-a-real-uuid.png")).toBe(false);
    expect(isOwnUploadedImageUrl("https://clog.run/uploads/../../etc/passwd")).toBe(false);
    expect(isOwnUploadedImageUrl("https://clog.run/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.exe")).toBe(false);
  });

  it("returns false for any URL when storage isn't configured - nothing could ever be a valid uploaded URL", async () => {
    delete process.env.UPLOAD_PUBLIC_BASE_URL;
    const { isOwnUploadedImageUrl } = await import("@/lib/storage/filesystem");
    expect(isOwnUploadedImageUrl("https://clog.run/uploads/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.png")).toBe(false);
  });
});
