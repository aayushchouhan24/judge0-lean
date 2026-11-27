Resque.redis = Redis.new(
  host:     ENV["REDIS_HOST"],
  port:     ENV["REDIS_PORT"],
  password: ENV["REDIS_PASSWORD"],
  thread_safe: true
)

# scripts/watchdog replaces worker pods whose heartbeat stops; a short interval lets it act fast.
Resque.heartbeat_interval = 15

if ENV["RESQUE_NAMESPACE"].present?
  Resque.redis.namespace = ENV["RESQUE_NAMESPACE"].to_sym
end
