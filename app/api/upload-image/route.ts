import { NextRequest, NextResponse } from "next/server";
import { uploadImage, isFilesystemStorageConfigured } from "@/lib/storage/filesystem";

export async function POST(request: NextRequest) {
  if (!isFilesystemStorageConfigured()) {
    return NextResponse.json({ error: "Image storage is not configured." }, { status: 503 });
  }

  let formData: FormData;
  try {
    formData = await request.formData();
  } catch {
    return NextResponse.json({ error: "Expected multipart/form-data." }, { status: 400 });
  }

  const file = formData.get("image");
  if (!(file instanceof File)) {
    return NextResponse.json({ error: "No image file provided." }, { status: 400 });
  }

  const buffer = Buffer.from(await file.arrayBuffer());
  const result = await uploadImage(buffer, file.type);

  if (!result.ok) {
    return NextResponse.json({ error: result.error }, { status: 400 });
  }

  return NextResponse.json({ url: result.url, key: result.key });
}
