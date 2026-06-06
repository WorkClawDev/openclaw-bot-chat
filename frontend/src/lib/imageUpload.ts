'use client'

import { assetsApi, getApiBase } from './api'
import type { Asset } from './types'

const AVATAR_SIZE = 512
const AVATAR_CONTENT_TYPE = 'image/png'

export async function uploadImageAsset(
  file: File,
  options: { conversationId?: string; fileName?: string } = {},
): Promise<Asset> {
  const prepared = await assetsApi.prepareImageUpload({
    file_name: options.fileName || file.name,
    content_type: file.type,
    size: file.size,
    conversation_id: options.conversationId,
  })

  const uploadResponse = await fetch(prepared.upload.url, {
    method: prepared.upload.method || 'PUT',
    headers: prepared.upload.headers,
    body: file,
  })

  if (!uploadResponse.ok) {
    throw new Error(`Upload failed with status ${uploadResponse.status}`)
  }

  return assetsApi.completeImageUpload({
    asset_id: prepared.asset.id || '',
    object_key: prepared.asset.object_key || '',
  })
}

export async function uploadAudioAsset(
  file: File,
  options: { conversationId?: string; fileName?: string } = {},
): Promise<Asset> {
  const prepared = await assetsApi.prepareAudioUpload({
    file_name: options.fileName || file.name,
    content_type: file.type,
    size: file.size,
    conversation_id: options.conversationId,
  })

  const uploadResponse = await fetch(prepared.upload.url, {
    method: prepared.upload.method || 'PUT',
    headers: prepared.upload.headers,
    body: file,
  })

  if (!uploadResponse.ok) {
    throw new Error(`Upload failed with status ${uploadResponse.status}`)
  }

  return assetsApi.completeAudioUpload({
    asset_id: prepared.asset.id || '',
    object_key: prepared.asset.object_key || '',
  })
}

export async function cropAndUploadAvatar(file: File): Promise<string> {
  const cropped = await cropImageToSquarePng(file, AVATAR_SIZE)
  const asset = await uploadImageAsset(cropped, { fileName: buildAvatarFileName(file.name) })
  if (!asset.id) {
    throw new Error('Avatar upload completed without an asset id')
  }
  return `${getApiBase()}/api/v1/assets/image/${encodeURIComponent(asset.id)}`
}

async function cropImageToSquarePng(file: File, size: number): Promise<File> {
  if (!file.type.startsWith('image/')) {
    throw new Error('Please choose an image file')
  }

  const image = await loadImage(file)
  const sourceSize = Math.min(image.naturalWidth, image.naturalHeight)
  const sourceX = Math.floor((image.naturalWidth - sourceSize) / 2)
  const sourceY = Math.floor((image.naturalHeight - sourceSize) / 2)
  const canvas = document.createElement('canvas')
  canvas.width = size
  canvas.height = size

  const context = canvas.getContext('2d')
  if (!context) {
    throw new Error('Image cropping is not supported in this browser')
  }

  context.drawImage(image, sourceX, sourceY, sourceSize, sourceSize, 0, 0, size, size)
  const blob = await canvasToBlob(canvas, AVATAR_CONTENT_TYPE)
  return new File([blob], buildAvatarFileName(file.name), { type: AVATAR_CONTENT_TYPE })
}

function loadImage(file: File): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const url = URL.createObjectURL(file)
    const image = new Image()
    image.onload = () => {
      URL.revokeObjectURL(url)
      resolve(image)
    }
    image.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new Error('Could not read the selected image'))
    }
    image.src = url
  })
}

function canvasToBlob(canvas: HTMLCanvasElement, contentType: string): Promise<Blob> {
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      if (!blob) {
        reject(new Error('Could not crop the selected image'))
        return
      }
      resolve(blob)
    }, contentType)
  })
}

function buildAvatarFileName(fileName: string): string {
  const baseName = fileName.replace(/\.[^.]+$/, '').replace(/[^a-zA-Z0-9_-]+/g, '-').replace(/^-|-$/g, '')
  return `${baseName || 'bot-avatar'}-avatar.png`
}
