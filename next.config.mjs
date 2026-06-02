/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Keep heavy server-only SDKs out of the bundler.
  serverExternalPackages: ["@stellar/stellar-sdk", "@prisma/client", "bcryptjs"],
};

export default nextConfig;
