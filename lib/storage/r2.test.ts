import { describe, it, expect, vi, beforeEach } from "vitest";

const sendMock = vi.fn();
vi.mock("@aws-sdk/client-s3", () => ({
  S3Client: vi.fn().mockImplementation(function S3ClientMock() {
    return { send: sendMock };
  }),
  PutObjectCommand: vi.fn().mockImplementation(function PutObjectCommandMock(input) {
    return { input };
  }),
}));

describe("R2 storage adapter", () => {
  beforeEach(() => {
    vi.resetModules();
    sendMock.mockReset();
    sendMock.mockResolvedValue({});
    process.env.R2_ENDPOINT = "https://example.r2.cloudflarestorage.com";
    process.env.R2_BUCKET = "clog-test-bucket";
    process.env.R2_ACCESS_KEY_ID = "test-key";
    process.env.R2_SECRET_ACCESS_KEY = "test-secret";
    process.env.R2_PUBLIC_BASE_URL = "https://assets.clog.run";
  });

  it("isR2Configured is false when any required env var is missing", async () => {
    delete process.env.R2_BUCKET;
    const { isR2Configured } = await import("@/lib/storage/r2");
    expect(isR2Configured()).toBe(false);
  });

  it("isR2Configured is true when every required env var is set", async () => {
    const { isR2Configured } = await import("@/lib/storage/r2");
    expect(isR2Configured()).toBe(true);
  });

  it("rejects an unsupported MIME type without calling S3 at all", async () => {
    const { uploadImage } = await import("@/lib/storage/r2");
    const result = await uploadImage(Buffer.from("not an image"), "application/pdf");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/Unsupported image type/);
    expect(sendMock).not.toHaveBeenCalled();
  });

  it("rejects a file over the size limit without calling S3 at all", async () => {
    const { uploadImage } = await import("@/lib/storage/r2");
    const oversized = Buffer.alloc(6 * 1024 * 1024); // 6 MB > 5 MB limit
    const result = await uploadImage(oversized, "image/png");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/too large/);
    expect(sendMock).not.toHaveBeenCalled();
  });

  it("accepts a valid PNG, uploads with the correct bucket/content-type, and returns a public URL under the object key", async () => {
    const { uploadImage } = await import("@/lib/storage/r2");
    const result = await uploadImage(Buffer.from("fake png bytes"), "image/png");
    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.key).toMatch(/^token-images\/[0-9a-f-]+\.png$/);
      expect(result.url).toBe(`https://assets.clog.run/${result.key}`);
    }
    expect(sendMock).toHaveBeenCalledTimes(1);
    const sentCommand = sendMock.mock.calls[0][0];
    expect(sentCommand.input.Bucket).toBe("clog-test-bucket");
    expect(sentCommand.input.ContentType).toBe("image/png");
  });

  it("two uploads of the same file never collide on the same key", async () => {
    const { uploadImage } = await import("@/lib/storage/r2");
    const bytes = Buffer.from("identical bytes");
    const first = await uploadImage(bytes, "image/jpeg");
    const second = await uploadImage(bytes, "image/jpeg");
    expect(first.ok && second.ok).toBe(true);
    if (first.ok && second.ok) {
      expect(first.key).not.toBe(second.key);
    }
  });

  it("reports a structured error (not a throw) when the underlying S3 call fails", async () => {
    sendMock.mockRejectedValueOnce(new Error("network unreachable"));
    const { uploadImage } = await import("@/lib/storage/r2");
    const result = await uploadImage(Buffer.from("bytes"), "image/webp");
    expect(result.ok).toBe(false);
    if (!result.ok) expect(result.error).toMatch(/network unreachable/);
  });

  it("refuses to upload at all when R2 is not configured", async () => {
    delete process.env.R2_ACCESS_KEY_ID;
    const { uploadImage } = await import("@/lib/storage/r2");
    const result = await uploadImage(Buffer.from("bytes"), "image/png");
    expect(result.ok).toBe(false);
    expect(sendMock).not.toHaveBeenCalled();
  });
});
