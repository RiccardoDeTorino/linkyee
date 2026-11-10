require_relative 'Plugin'
require 'nokogiri'
require 'time'

# Fetch the latest video for one or more YouTube channels.
# Uses YouTube's public Atom feed — no API key required.
# Accepts a channel ID, handle, or YouTube channel URL.
class YouTubeChannelLatestVideoPlugin < Plugin
  BROWSER_HEADERS = {
    'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
    'Accept-Language' => 'en-US,en;q=0.9'
  }.freeze

  EMPTY = {
    'title' => '', 'url' => '', 'video_id' => '',
    'thumbnail' => '', 'published' => '', 'channel' => ''
  }.freeze

  def execute
    args.each_with_object({}) do |input, out|
      channel_url = channel_page_url(input)
      video = cache("yt-latest:#{input}") { load_latest(input) } || EMPTY.dup
      # Retain a useful channel link only if the latest-video lookup failed.
      video = video.merge('url' => channel_url) if video['url'].to_s.empty? && channel_url
      out[input] = video
    end
  end

  private

  def load_latest(input)
    channel_id = resolve_channel_id(input)
    unless channel_id
      log("could not resolve channel ID for #{input.inspect}; check YouTube response in this build")
      return nil
    end

    feed_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{URI.encode_www_form_component(channel_id)}"
    res = http_get(feed_url)
    unless res.is_a?(Net::HTTPSuccess)
      log("Atom feed request failed for #{input.inspect}: #{res&.code} #{res&.message}")
      return nil
    end

    doc = Nokogiri::XML(res.body) do |config|
      config.nonet
      config.noblanks
    end
    channel = doc.at_xpath('//*[local-name()="feed"]/*[local-name()="title"]')&.text.to_s.strip
    entry = doc.at_xpath('//*[local-name()="feed"]/*[local-name()="entry"]')
    unless entry
      log("Atom feed returned no entries for #{input.inspect}")
      return EMPTY.dup.merge('channel' => channel)
    end

    video_id = entry.at_xpath('.//*[local-name()="videoId"]')&.text.to_s.strip
    title = entry.at_xpath('./*[local-name()="title"]')&.text.to_s.strip
    published = entry.at_xpath('./*[local-name()="published"]')&.text.to_s
    feed_link = entry.xpath('./*[local-name()="link"]').find { |node| node['rel'].to_s.empty? || node['rel'] == 'alternate' }&.[]('href').to_s
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
  # successfully resolved ID.
  def resolve_channel_id(input)
    cache("yt:resolve:#{input}") do
      str = input.to_s.strip
      return str if valid_channel_id?(str)

      url = if str.start_with?('http://', 'https://')
              str
            elsif str.start_with?('@')
              "https://www.youtube.com/#{str}"
            else
              "https://www.youtube.com/@#{str}"
            end

      direct_id = channel_id_from_text(url)
      next direct_id if direct_id

      res = http_get(url, headers: BROWSER_HEADERS)
      unless res.is_a?(Net::HTTPSuccess)
        log("channel page request failed for #{url}: #{res&.code} #{res&.message}")
        next nil
      end

      channel_id_from_text(res.body)
    end
  end

  def channel_id_from_text(text)
    source = text.to_s
    patterns = [
      %r{youtube\.com/channel/(UC[A-Za-z0-9_-]{20,})},
      /["'](?:channelId|externalId|browseId|channel_id)["']\s*:\s*["'](UC[A-Za-z0-9_-]{20,})["']/, 
      /itemprop=["']channelId["']\s+content=["'](UC[A-Za-z0-9_-]{20,})["']/, 
      /data-channel-external-id=["'](UC[A-Za-z0-9_-]{20,})["']/, 
      /\b(UC[A-Za-z0-9_-]{22})\b/
    ]
    patterns.each do |pattern|
      match = source.match(pattern)
      return match[1] if match && valid_channel_id?(match[1])
    end
    nil
  end

  def valid_channel_id?(value)
    value.to_s.match?(/\AUC[A-Za-z0-9_-]{20,24}\z/)
  end

  def channel_page_url(input)
    value = input.to_s.strip
    return nil if value.empty?

    if valid_channel_id?(value)
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
