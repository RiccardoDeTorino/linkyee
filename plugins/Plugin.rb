require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

# Base class for all linkyee plugins.
# Plugins implement `execute` and return data made available to Liquid as vars.<PluginName>.
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

  # GET an HTTP(S) URL with redirect following. Returns a response or nil.
  def http_get(url, headers: {}, redirect_limit: 5, timeout: 15)
    return nil if redirect_limit <= 0

    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    default_headers.merge(headers).each { |key, value| req[key] = value }
    response = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: timeout, read_timeout: timeout
    ) { |http| http.request(req) }

    if response.is_a?(Net::HTTPRedirection)
      http_get(response['location'], headers: headers, redirect_limit: redirect_limit - 1, timeout: timeout)
    else
      response
    end
  rescue StandardError => e
    log("http_get(#{url}) failed: #{e.class}: #{e.message}")
    nil
  end

  def http_get_json(url, headers: {}, default: nil, **opts)
    response = http_get(url, headers: { 'Accept' => 'application/json' }.merge(headers), **opts)
    return default unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    log("http_get_json(#{url}) parse failed: #{e.message}")
    default
  end

  # POST JSON and parse a JSON response. Returns `default` on any failure.
  def http_post_json(url, payload:, headers: {}, default: nil, timeout: 15)
    uri = URI(url)
    request = Net::HTTP::Post.new(uri)
    default_headers.merge(
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    ).merge(headers).each { |key, value| request[key] = value }
    request.body = JSON.generate(payload)

    response = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: timeout, read_timeout: timeout
    ) { |http| http.request(request) }
    return default unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue JSON::ParserError => e
    log("http_post_json(#{url}) parse failed: #{e.message}")
    default
  rescue StandardError => e
    log("http_post_json(#{url}) failed: #{e.class}: #{e.message}")
    default
  end

  # Refresh on each build; fall back to the last successfully cached result.
  def cache(key)
    return Plugin.cache_store[key] if Plugin.cache_store.key?(key)

    path = Plugin.disk_cache_path(key)
    value = yield
    unless value.nil?
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
        # Ignore corrupt cached data.
      end
    end
    nil
  end

  def log(message)
    warn "[#{self.class.name}] #{message}"
  end

  def self.cache_store
    @cache_store ||= {}
  end

  def self.disk_cache_dir
    './.linkyee-cache'
  end

  def self.disk_cache_path(key)
    slug = key.gsub(/[^A-Za-z0-9._@-]+/, '--')[0, 200]
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
