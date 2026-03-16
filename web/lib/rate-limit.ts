// Simple in-memory rate limiter for API routes
// SECURITY: Prevents abuse of public API endpoints

interface RateLimitEntry {
  count: number;
  resetAt: number;
}

const store = new Map<string, RateLimitEntry>();

// Clean up expired entries periodically
setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of store) {
    if (now >= entry.resetAt) store.delete(key);
  }
}, 60_000);

/**
 * Check rate limit for an IP/key. Returns { allowed, remaining, resetAt }.
 * @param key - Unique identifier (IP address or API key)
 * @param maxRequests - Max requests per window (default: 60)
 * @param windowMs - Window duration in ms (default: 60000 = 1 minute)
 */
export function checkRateLimit(
  key: string,
  maxRequests = 60,
  windowMs = 60_000,
): { allowed: boolean; remaining: number; resetAt: number } {
  const now = Date.now();
  const entry = store.get(key);

  if (!entry || now >= entry.resetAt) {
    store.set(key, { count: 1, resetAt: now + windowMs });
    return { allowed: true, remaining: maxRequests - 1, resetAt: now + windowMs };
  }

  entry.count++;
  const remaining = Math.max(0, maxRequests - entry.count);
  return { allowed: entry.count <= maxRequests, remaining, resetAt: entry.resetAt };
}

/**
 * Validate a Sui address format (0x + 64 hex chars)
 */
export function isValidSuiAddress(address: string): boolean {
  return /^0x[a-fA-F0-9]{64}$/.test(address);
}
