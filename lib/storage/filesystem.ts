import "server-only";
import { randomUUID } from "node:crypto";
import { mkdir, rename, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

/**
 * Local persistent-filesystem upload adapter for v1 (replaces the earlier R2
 * adapter - see git history if R2 is ever revisited). Deliberately kept to
 * the same shape (isConfigured/uploadImage returning {ok, url, key} |
 * {ok:false, error}) as the R2 adapter it replaces, so a future swap back to
 * S3-compatible storage would only need a new adapter file, not application
 * changes - the upload route and callers depend on this shape, not on how
 * bytes actually get persisted.
 *
 * Env vars (server-only, never NEXT_PUBLIC_*):
 *   UPLOAD_DIR             - e.g. /var/lib/clog/uploads in production.
 *                            Deliberately outside /opt/clogged (the app
 *                            deployment directory) so uploaded files survive
 *                            a git pull / redeploy independently.
 *   UPLOAD_PUBLIC_BASE_URL - the public URL prefix these files are served
 *                            under, e.g. https://clog.run/uploads - Nginx
 *                            serves this directly (see the Nginx config),
 *                            not Next.js.
 */

const ALLOWED_MIME_TYPES: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/webp": "webp",
  "image/gif": "gif",
};

const MAX_FILE_SIZE_BYTES = 5 * 1024 * 1024; // 5 MB - generous for a meme image, not unbounded

export interface UploadResult {
  ok: true;
  url: string;
  key: string;
}

export interface UploadError {
  ok: false;
  error: string;
}

export function isFilesystemStorageConfigured(): boolean {
  return Boolean(process.env.UPLOAD_DIR && process.env.UPLOAD_PUBLIC_BASE_URL);
}

/**
 * Uploads a single image to the local filesystem. Validates MIME type and
 * size, generates a non-colliding filename (a random UUID plus the
 * extension implied by the VALIDATED MIME type - never the original
 * filename or any user-supplied string, which is exactly what makes path
 * traversal structurally impossible here: nothing derived from user input
 * ever becomes part of a filesystem path). Writes to a temp file in the
 * same directory first, then renames into place - `rename` is atomic on the
 * same filesystem, so a reader can never observe a partially-written file
 * at the final path.
 */
export async function uploadImage(buffer: Buffer, mimeType: string): Promise<UploadResult | UploadError> {
  if (!isFilesystemStorageConfigured()) {
    return { ok: false, error: "Image storage is not configured." };
  }

  const extension = ALLOWED_MIME_TYPES[mimeType];
  if (!extension) {
    return { ok: false, error: `Unsupported image type: ${mimeType}. Allowed: PNG, JPEG, WEBP, GIF.` };
  }

  if (buffer.byteLength > MAX_FILE_SIZE_BYTES) {
    return { ok: false, error: `Image too large - max ${MAX_FILE_SIZE_BYTES / (1024 * 1024)} MB.` };
  }

  const uploadDir = process.env.UPLOAD_DIR!;
  const filename = `${randomUUID()}.${extension}`;
  const finalPath = path.join(uploadDir, filename);
  const tmpPath = path.join(uploadDir, `.tmp-${randomUUID()}`);

  try {
    await mkdir(uploadDir, { recursive: true });
    await writeFile(tmpPath, buffer);
    await rename(tmpPath, finalPath);
  } catch (err) {
    // Best-effort cleanup of the temp file if the rename step itself is
    // what failed - never leave partial temp files lying around.
    await unlink(tmpPath).catch(() => {});
    return { ok: false, error: err instanceof Error ? err.message : "Upload failed." };
  }

  const base = process.env.UPLOAD_PUBLIC_BASE_URL!.replace(/\/+$/, "");
  return { ok: true, url: `${base}/${filename}`, key: filename };
}
