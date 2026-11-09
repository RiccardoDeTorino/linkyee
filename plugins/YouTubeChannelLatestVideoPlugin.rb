require_relative 'Plugin'
require 'nokogiri'
require 'time'

# Fetch the latest video for one or more YouTube channels.
# Uses YouTube's public Atom feed — no API key required.
# Accepts a channel ID, handle, or YouTube channel URL.
class YouTubeChannelLatestVideoPlugin < Plugin
  EMPTY = {
    'title' => '', 'url' => '', 'video_id' => '',
    'thumbnail' => '', 'published' => '', 'channel' => ''
  }.freeze

  def execute
    args.each_with_object({}) do |input, out|
      channel_url = channel_page_url(input)
      video = cache("yt-latest:#{input}") { load_latest(input) } || EMPTY.dup
      # Keep the link useful if YouTube blocks channel resolution or the feed
      # is unavailable: fall back to the channel page rather than href="".
      video = video.merge('url' => channel_url) if video['url'].to_s.empty? && channel_url
      out[input] = video
    end
  end

  private

  def load_latest(input)
    channel_id = resolve_channel_id(input)
    unless channel_id
      log("could not resolve YouTube channel #{input.inspect}; using channel URL fallback")
      return nil
    end

    feed_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{URI.encode_www_form_component(channel_id)}"
    res = http_get(feed_url)
    unless res.is_a?(Net::HTTPSuccess)
      log("video feed fetch failed for #{input.inspect}: #{res&.code} #{res&.message}")
      return nil
    end

    doc = Nokogiri::XML(res.body) do |config|
      config.nonet
      config.noblanks
    end
    channel = doc.at_xpath('//xmlns:feed/xmlns:title')&.text.to_s.strip
    entry = doc.at_xpath('//xmlns:feed/xmlns:entry')
    unless entry
      log("video feed contained no entries for #{input.inspect}; using channel URL fallback")
      return EMPTY.dup.merge('channel' => channel)
    end

    video_id = entry.at_xpath('yt:videoId', 'yt' => 'http://www.youtube.com/xml/schemas/2015')&.text.to_s.strip
    title = entry.at_xpath('xmlns:title')&.text.to_s.strip
    published = entry.at_xpath('xmlns:published')&.text.to_s
    feed_link = entry.at_xpath('xmlns:link')&.[]('href').to_s
    video_url = video_id.empty? ? '' : "https://www.youtube.com/watch?v=#{video_id}"
    video_url = feed_link if video_url.empty? && valid_youtube_url?(feed_link)

    {
      'title' => title,
      'url' => video_url,
      'video_id' => video_id,
      'thumbnail' => video_id.empty? ? '' : "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg",
      'published' => normalize_date(published),
      'channel' => channel
    }
  rescue StandardError => e
    log("latest-video lookup for #{input.inspect} failed: #{e.class}: #{e.message}")
    nil
  end

  # Accept channel_id (UC…), handle (@name), or YouTube URL → channel_id.
  # Resolution is disk-cached so transient network failures can use the last
  # successful channel ID.
  def resolve_channel_id(input)
    cache("yt:resolve:#{input}") do
      str = input.to_s.strip
      return str if str.match?(/\AUC[A-Za-z0-9_-]{20,}\z/)

      url = if str.start_with?('http://', 'https://')
              str
            elsif str.start_with?('@')
              "https://www.youtube.com/#{str}"
            else
              "https://www.youtube.com/@#{str}"
            end

      if (match = url.match(%r{youtube\.com/channel/(UC[A-Za-z0-9_-]+)}))
        next match[1]
      end

      res = http_get(url, headers: { 'User-Agent' => 'Mozilla/5.0' })
      next nil unless res.is_a?(Net::HTTPSuccess)

      match = res.body.match(%r{youtube\.com/channel/(UC[A-Za-z0-9_-]{10,})}) ||
              res.body.match(/"channelId":"(UC[A-Za-z0-9_-]+)"/) ||
              res.body.match(/itemprop="channelId" content="(UC[A-Za-z0-9_-]+)"/) ||
              res.body.match(/\b(UC[A-Za-z0-9_-]{20,24})\b/)
      match && match[1]
    end
  end

  def channel_page_url(input)
    value = input.to_s.strip
    return nil if value.empty?

    if value.match?(/\AUC[A-Za-z0-9_-]{20,}\z/)
      "https://www.youtube.com/channel/#{value}"
    elsif value.start_with?('http://', 'https://')
      uri = URI.parse(value)
      return nil unless %w[youtube.com www.youtube.com m.youtube.com].include?(uri.host)
      uri.to_s
    else
      handle = value.start_with?('@') ? value : "@#{value}"
      "https://www.youtube.com/#{handle}"
    end
  rescue URI::InvalidURIError
    nil
  end

  def valid_youtube_url?(value)
    uri = URI.parse(value.to_s)
    %w[youtube.com www.youtube.com m.youtube.com].include?(uri.host) && %w[http https].include?(uri.scheme)
  rescue URI::InvalidURIError
    false
  end

  def normalize_date(raw)
    return '' if raw.to_s.empty?

    Time.parse(raw).strftime('%Y-%m-%d')
  rescue ArgumentError
    raw.to_s[0, 10]
  end
end
