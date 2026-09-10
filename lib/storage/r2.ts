import "server-only";
import { S3Client, PutObjectCommand } from "@aws-sdk/client-s3";
import { randomUUID } from "node:crypto";

/**
 * S3-compatible upload adapter for Cloudflare R2. Uses the official AWS SDK
 * (R2 implements the S3 API directly - no R2-specific SDK needed, matching
 * the reuse-first approach the rest of this project follows).
 *
 * Env vars (never exposed as NEXT_PUBLIC_*, read only server-side):
 *   R2_ENDPOINT          - e.g. https://<account-id>.r2.cloudflarestorage.com
 *   R2_BUCKET            - bucket name
 *   R2_ACCESS_KEY_ID     - R2 API token access key
 *   R2_SECRET_ACCESS_KEY - R2 API token secret
 *   R2_PUBLIC_BASE_URL   - the public URL prefix objects are served from,
 *                          e.g. https://assets.clog.run/ (a custom domain)
 *                          or an r2.dev public bucket URL - the code does
 *                          not require any specific hostname.
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

export function isR2Configured(): boolean {
  return Boolean(
    process.env.R2_ENDPOINT &&
      process.env.R2_BUCKET &&
      process.env.R2_ACCESS_KEY_ID &&
      process.env.R2_SECRET_ACCESS_KEY &&
      process.env.R2_PUBLIC_BASE_URL
  );
}

function getClient(): S3Client {
  return new S3Client({
    region: "auto", // R2 does not use AWS regions; "auto" is R2's own documented convention
    endpoint: process.env.R2_ENDPOINT,
    credentials: {
      accessKeyId: process.env.R2_ACCESS_KEY_ID!,
      secretAccessKey: process.env.R2_SECRET_ACCESS_KEY!,
    },
  });
}

/**
 * Uploads a single image. Validates MIME type and size, generates a
 * non-colliding object key (a random UUID plus the extension implied by the
 * validated MIME type - never the original filename, which is untrusted
 * input and must never be used as a storage path). Returns the public URL
 * built from R2_PUBLIC_BASE_URL, or a structured error - never throws for
 * an expected validation failure.
 */
export async function uploadImage(buffer: Buffer, mimeType: string): Promise<UploadResult | UploadError> {
  if (!isR2Configured()) {
    return { ok: false, error: "Image storage is not configured." };
  }

  const extension = ALLOWED_MIME_TYPES[mimeType];
  if (!extension) {
    return { ok: false, error: `Unsupported image type: ${mimeType}. Allowed: PNG, JPEG, WEBP, GIF.` };
  }

  if (buffer.byteLength > MAX_FILE_SIZE_BYTES) {
    return { ok: false, error: `Image too large - max ${MAX_FILE_SIZE_BYTES / (1024 * 1024)} MB.` };
  }

  const key = `token-images/${randomUUID()}.${extension}`;

  try {
    const client = getClient();
    await client.send(
      new PutObjectCommand({
        Bucket: process.env.R2_BUCKET,
        Key: key,
        Body: buffer,
        ContentType: mimeType,
        CacheControl: "public, max-age=31536000, immutable", // random UUID keys are never reused/overwritten
      })
    );

    const base = process.env.R2_PUBLIC_BASE_URL!.replace(/\/+$/, "");
    return { ok: true, url: `${base}/${key}`, key };
  } catch (err) {
    return { ok: false, error: err instanceof Error ? err.message : "Upload failed." };
  }
}
