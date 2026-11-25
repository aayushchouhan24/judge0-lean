# Redis connection that stores submissions (separate from Resque's namespaced connection).
JUDGE0_REDIS = Redis.new(
  host:     ENV["REDIS_HOST"],
  port:     ENV["REDIS_PORT"],
  password: ENV["REDIS_PASSWORD"].presence,
  db:       (ENV["REDIS_DB"].presence || 0).to_i,
  thread_safe: true
)
