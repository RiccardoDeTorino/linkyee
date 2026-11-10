require_relative 'Plugin'
require 'nokogiri'
require 'time'
require 'uri'

# Fetch the latest video for one or more YouTube channels using YouTube's
# public Atom feed (no API key required). Accepts a channel ID, handle, or URL.
class YouTubeChannelLatestVideoPlugin < Plugin
  USER_AGENT = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36'.freeze
  EMPTY = {
    'title' => nil, 'url' => nil, 'video_id' => nil,
    'thumbnail' => nil, 'published' => nil, 'channel' => nil
  }.freeze

  def execute
    args.each_with_object({}) do |input, out|
      out[input] = cache("yt-latest:#{input}") { load_latest(input) } || EMPTY.dup
    end
  end

  private

  def load_latest(input)
    channel_id = resolve_channel_id(input)
    unless channel_id
      log("could not resolve channel ID for #{input.inspect}; channel page could not be parsed")
      return nil
    end

    feed_url = "https://www.youtube.com/feeds/videos.xml?channel_id=#{URI.encode_www_form_component(channel_id)}"
    response = http_get(feed_url, headers: { 'User-Agent' => USER_AGENT, 'Accept' => 'application/atom+xml,application/xml,text/xml' })
    unless response.is_a?(Net::HTTPSuccess)
      log("Atom feed request failed for #{input.inspect} (#{channel_id}): #{response&.code} #{response&.message}")
      return nil
    end

    doc = Nokogiri::XML(response.body) { |config| config.nonet }
    entry = doc.at_xpath('//*[local-name()="entry"]')
    channel_name = doc.at_xpath('//*[local-name()="feed"]/*[local-name()="title"]')&.text.to_s.strip
    unless entry
      log("Atom feed has no video entries for #{input.inspect} (#{channel_id})")
      return EMPTY.dup.merge('channel' => channel_name)
    end

    video_id = entry.at_xpath('./*[local-name()="videoId"]')&.text.to_s.strip
    title = entry.at_xpath('./*[local-name()="title"]')&.text.to_s.strip
    published = entry.at_xpath('./*[local-name()="published"]')&.text.to_s
    url = video_id.empty? ? '' : "https://www.youtube.com/watch?v=#{video_id}"
    # The Atom alternate link is normally the watch URL; retain it if the
    # videoId element is absent in a future feed format.
    if url.empty?
      link = entry.xpath('./*[local-name()="link"]').find { |node| node['rel'].to_s.empty? || node['rel'] == 'alternate' }
      url = link&.[]('href').to_s
    end

    {
      'title' => title,
      'url' => url,
      'video_id' => video_id,
      'thumbnail' => video_id.empty? ? '' : "https://i.ytimg.com/vi/#{video_id}/hqdefault.jpg",
      'published' => normalize_date(published),
      'channel' => channel_name
    }
  rescue StandardError => e
    log("latest-video lookup for #{input.inspect} failed: #{e.class}: #{e.message}")
    nil
  end

  # Accept channel_id (UC…), handle (@name), or YouTube channel URL → ID.
  # Keep the resolved ID in the existing disk cache for builds where YouTube
  # temporarily blocks or changes its channel-page HTML.
  def resolve_channel_id(input)
    cache("yt:resolve:#{input}") do
      value = input.to_s.strip
      return value if valid_channel_id?(value)

      url = channel_page_url(value)
      next nil unless url

      direct_id = channel_id_from_text(url)
      next direct_id if direct_id

      # YouTube often serves richer channel metadata with an explicit locale.
      page_url = url.include?('?') ? "#{url}&hl=en" : "#{url}?hl=en"
      response = http_get(
        page_url,
        headers: {
          'User-Agent' => USER_AGENT,
          'Accept-Language' => 'en-US,en;q=0.9',
          'Accept' => 'text/html,application/xhtml+xml'
        },
        timeout: 25
      )
      unless response.is_a?(Net::HTTPSuccess)
        log("channel page request failed for #{value.inspect}: #{response&.code} #{response&.message}")
        next nil
      end

      extract_channel_id(response.body)
    end
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

  def extract_channel_id(html)
    source = html.to_s
    # Parse semantic metadata first, then known YouTube page JSON fields.
    doc = Nokogiri::HTML(source) { |config| config.nonet }
    meta_id = doc.at_xpath('//*[@itemprop="channelId"]/@content')&.value
    return meta_id if valid_channel_id?(meta_id)

    patterns = [
      %r{youtube\.com/channel/(UC[A-Za-z0-9_-]{22})},
      /["'](?:externalId|channelId|browseId|channel_id)["']\s*:\s*["'](UC[A-Za-z0-9_-]{22})["']/, 
      /data-channel-external-id\s*=\s*["'](UC[A-Za-z0-9_-]{22})["']/,
      /\b(UC[A-Za-z0-9_-]{22})\b/
    ]
    patterns.each do |pattern|
      match = source.match(pattern)
      return match[1] if match && valid_channel_id?(match[1])
    end
    nil
  end

  def channel_id_from_text(value)
    match = value.to_s.match(%r{youtube\.com/channel/(UC[A-Za-z0-9_-]{22})})
    match && match[1]
  end

  def valid_channel_id?(value)
    value.to_s.match?(/\AUC[A-Za-z0-9_-]{22}\z/)
  end

  def normalize_date(raw)
    return '' if raw.to_s.empty?

    Time.parse(raw).strftime('%Y-%m-%d')
  rescue ArgumentError
    raw.to_s[0, 10]
  end
end
