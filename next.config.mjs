/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // Keep heavy server-only SDKs out of the bundler.
  serverExternalPackages: ["@prisma/client", "bcryptjs"],
  webpack: (config) => {
    // wagmi's connectors barrel pulls in an unused "tempo" connector that
    // references a bare `accounts` specifier; we only use coinbaseWallet, so
    // ignore it to keep the bundle resolvable.
    config.resolve.alias = { ...(config.resolve.alias || {}), accounts: false };
    return config;
  },
};

export default nextConfig;
