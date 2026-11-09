require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

# Base class for all linkyee plugins.
#
# A plugin is a Ruby class living under `./plugins/<ClassName>.rb` that is
# enabled via `config.yml`:
#
#   plugins:
#     - MyPlugin:
#         - some
#         - args
#
# At build time scaffold.rb instantiates `<PluginName>.new(<values from yaml>)`
# and calls `execute`. Whatever `execute` returns is stored under
# `vars.<PluginName>` and is then available inside `config.yml` and theme
# templates as `{{ vars.<PluginName> }}` (Liquid).
#
# ─── Subclass contract ────────────────────────────────────────────────
#
# Subclasses MUST:
#   - Inherit from Plugin (`class MyPlugin < Plugin`)
#   - Be saved as `./plugins/MyPlugin.rb` (filename == class name)
#   - Override `execute` and return a value Liquid can render
#     (String, Numeric, Hash with String keys, Array, or nested combos).
#
# Subclasses SHOULD:
#   - Use the helpers below (`http_get`, `http_get_json`, `http_post_json`, `log`, `cache`)
#     instead of reaching for Net::HTTP directly. They follow redirects where
#     appropriate, set a sensible User-Agent, and return safe defaults on failure.
#   - Be defensive: a flaky external API should NOT break the whole build.
#     If a fetch fails, return a safe default (0, "", {}, []).
class Plugin
  attr_reader :data

  def initialize(data)
    @data = data
  end

  def execute
  end

  def args
    first = Array(@data).first
    first.is_a?(Array) ? first : (first.nil? ? [] : [first])
  end

  def params
    first = Array(@data).first
    first.is_a?(Hash) ? first : {}
  end

  # GET an HTTP(S) URL with redirect following. Returns Net::HTTPResponse,
  # or nil on failure. Never raises.
  def http_get(url, headers: {}, redirect_limit: 5, timeout: 15)
    return nil if redirect_limit <= 0

    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    default_headers.merge(headers).each { |k, v| req[k] = v }

    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: timeout, read_timeout: timeout
    ) { |http| http.request(req) }

    case res
    when Net::HTTPRedirection
      http_get(res['location'], headers: headers, redirect_limit: redirect_limit - 1, timeout: timeout)
    else
      res
    end
  rescue StandardError => e
    log("http_get(#{url}) failed: #{e.class}: #{e.message}")
    nil
  end

  # GET a URL and parse the body as JSON. Returns parsed value, or `default`
  # on failure (network, non-2xx, malformed JSON).
  def http_get_json(url, headers: {}, default: nil, **opts)
    res = http_get(url, headers: { 'Accept' => 'application/json' }.merge(headers), **opts)
    return default unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError => e
    log("http_get_json(#{url}) parse failed: #{e.message}")
    default
  end

  # POST a JSON payload and parse the JSON response. Returns `default` on
  # network, HTTP, or JSON parsing failure.
  def http_post_json(url, payload:, headers: {}, default: nil, timeout: 15)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    default_headers.merge(
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    ).merge(headers).each { |k, v| req[k] = v }
    req.body = JSON.generate(payload)

    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: timeout, read_timeout: timeout
    ) { |http| http.request(req) }
    return default unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError => e
    log("http_post_json(#{url}) parse failed: #{e.message}")
    default
  rescue StandardError => e
    log("http_post_json(#{url}) failed: #{e.class}: #{e.message}")
    default
  end

  # Cache with stale-on-failure semantics — no TTL.
  def cache(key)
    return Plugin.cache_store[key] if Plugin.cache_store.key?(key)
    path = Plugin.disk_cache_path(key)
    value = yield

    if !value.nil?
      Plugin.cache_store[key] = value
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(value))
      return value
    end

    if File.exist?(path)
      begin
        cached = JSON.parse(File.read(path))
        Plugin.cache_store[key] = cached
        log("fetch failed for #{key}; using cached value")
        return cached
      rescue JSON::ParserError
        # Corrupt cache file — fall through to nil.
      end
    end
    nil
  end

  def log(msg)
    warn "[#{self.class.name}] #{msg}"
  end

  def self.cache_store
    @cache_store ||= {}
  end

  def self.disk_cache_dir
    './.linkyee-cache'
  end

  def self.disk_cache_path(key)
    slug = key.gsub(/[^A-Za-z0-9._@-]+/, '--')
    slug = slug[0, 200]
    File.join(disk_cache_dir, "#{slug}.json")
  end

  private

  def default_headers
    {
      'User-Agent' => 'linkyee/1.0 (+https://github.com/ZhgChgLi/linkyee)',
      'Accept' => '*/*'
    }
  end
end
