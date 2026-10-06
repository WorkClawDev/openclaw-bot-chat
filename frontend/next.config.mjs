/** @type {import('next').NextConfig} */
const nextConfig = {
  distDir: process.env.NEXT_DIST_DIR || '.next',
  reactStrictMode: true,
  ...(process.env.NEXT_STANDALONE === '1' ? { output: 'standalone' } : {}),
}

export default nextConfig
