require_relative 'Plugin'
require 'nokogiri'
require 'time'
require 'uri'

# Fetch the latest video for one or more Odysee channels using their public RSS feed.
# Accepts a channel URL, @handle, or raw channel slug.
class OdyseeChannelLatestVideoPlugin < Plugin
  EMPTY = {
    'title' => '', 'url' => '', 'video_id' => '',
    'thumbnail' => '', 'published' => '', 'channel' => ''
  }.freeze

  def execute
    args.each_with_object({}) do |input, out|
      channel_url = resolve_channel_url(input)
      video = cache("odysee-latest:#{input}") { load_latest(channel_url) } || EMPTY.dup
      # Do not emit href="" when Odysee's feed is unavailable or has an
      # unexpected format. The channel page is a safe fallback, not the site root.
      video = video.merge('url' => channel_url) if video['url'].to_s.empty? && channel_url
      out[input] = video
    end
  end

  private

  def load_latest(channel_url)
    return nil unless channel_url

    feed_url = build_feed_url(channel_url)
    res = http_get(feed_url, headers: {
      'User-Agent' => 'Mozilla/5.0 (compatible; linkyee Odysee reader; +https://github.com/ZhgChgLi/linkyee)',
      'Accept' => 'application/rss+xml, application/atom+xml, application/xml, text/xml, */*'
    })
    unless res.is_a?(Net::HTTPSuccess)
      warn "[OdyseeChannelLatestVideoPlugin] Feed fetch failed for #{feed_url}: #{res&.code} #{res&.message}"
      return nil
    end

    doc = Nokogiri::XML(res.body.to_s) do |config|
      config.nonet
      config.noblanks
    end

    channel = doc.at_xpath('//*[local-name()="channel"]/*[local-name()="title"]')&.text.to_s.strip
    channel = doc.at_xpath('/*[local-name()="feed"]/*[local-name()="title"]')&.text.to_s.strip if channel.empty?
    entry = doc.at_xpath('//*[local-name()="item" or local-name()="entry"]')
    unless entry
      detail = doc.errors.map(&:message).join('; ')
      warn "[OdyseeChannelLatestVideoPlugin] No RSS items or Atom entries in #{feed_url}#{": #{detail}" unless detail.empty?}"
      return nil
    end

    title = child_text(entry, 'title')
    url = preferred_link(entry)
    unless url
      warn "[OdyseeChannelLatestVideoPlugin] No usable video link in latest feed item (#{feed_url}); linking to channel instead"
      return {
        'title' => title,
        'url' => channel_url,
        'video_id' => '',
        'thumbnail' => thumbnail_for(entry),
        'published' => normalize_date(first_present(entry, 'pubDate', 'updated', 'published')),
        'channel' => channel
      }
    end

    {
      'title' => title,
      'url' => url,
      'video_id' => parse_video_id(url),
      'thumbnail' => thumbnail_for(entry),
      'published' => normalize_date(first_present(entry, 'pubDate', 'updated', 'published')),
      'channel' => channel
    }
  rescue StandardError => e
    warn "[OdyseeChannelLatestVideoPlugin] Failed to parse #{feed_url}: #{e.class}: #{e.message}"
    nil
  end

  # Odysee's RSS endpoint is /$/rss/<channel-path>, not <channel-path>/rss.
  def build_feed_url(channel_url)
    uri = URI.parse(channel_url)
    channel_path = uri.path.to_s.sub(%r{\A/+}, '')
    uri.scheme = 'https'
    uri.path = "/$/rss/#{channel_path}" unless channel_path.start_with?('$/rss/')
    uri.query = nil
    uri.fragment = nil
    uri.to_s
  end

  def resolve_channel_url(input)
    str = input.to_s.strip
    return nil if str.empty?

    if str.start_with?('http://', 'https://')
      clean_url(str)
    elsif str.start_with?('@')
      "https://odysee.com/#{str}"
    elsif str.include?('/')
      "https://odysee.com/#{str.sub(%r{\A/+}, '')}"
    else
      "https://odysee.com/@#{str.sub(%r{\A@}, '')}"
    end
  end

  def clean_url(url)
    uri = URI.parse(url)
    return nil unless %w[http https].include?(uri.scheme) && %w[odysee.com www.odysee.com].include?(uri.host)

    uri.query = nil
    uri.fragment = nil
    uri.path = '/' if uri.path.to_s.empty?
    uri.to_s.sub(%r{/+\z}, '')
  rescue URI::InvalidURIError
    nil
  end

  def preferred_link(node)
    candidates = node.xpath('./*[local-name()="link"]').map do |link_node|
      href = link_node['href'].to_s.strip
      href.empty? ? link_node.text.to_s.strip : href
    end
    candidates << node.at_xpath('./*[local-name()="guid"]')&.text.to_s.strip
    candidates.each do |candidate|
      normalized = normalize_video_url(candidate)
      return normalized if normalized
    end
    nil
  end

  # Odysee/LBRY feeds may use lbry:// links, protocol-relative URLs, or
  # relative paths rather than absolute HTTP URLs.
  def normalize_video_url(candidate)
    value = candidate.to_s.strip
    return nil if value.empty?

    if value.start_with?('lbry://')
      value = "https://odysee.com/#{value.delete_prefix('lbry://').sub(%r{\A/+}, '')}"
    elsif value.start_with?('//')
      value = "https:#{value}"
    elsif !value.match?(%r{\Ahttps?://}i)
      value = URI.join('https://odysee.com/', value).to_s
    end

    uri = URI.parse(value)
    return nil unless %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def thumbnail_for(node)
    candidate = node.at_xpath('./*[local-name()="thumbnail"]')&.[]('url') ||
      node.at_xpath('./*[local-name()="image"]')&.text.to_s.strip ||
      node.at_xpath('./*[local-name()="thumbnail"]')&.text.to_s.strip ||
      node.at_xpath('.//*[local-name()="thumbnail"]')&.[]('url').to_s

    return candidate.strip unless candidate.to_s.empty?

    node.at_xpath('./*[local-name()="enclosure"]')&.[]('url').to_s.strip
  end

  def child_text(node, name)
    node.at_xpath("./*[local-name()=#{name.to_json}]")&.text.to_s.strip
  end

  def first_present(node, *names)
    names.each do |name|
      value = child_text(node, name)
      return value unless value.empty?
    end
    ''
  end

  def parse_video_id(url)
    return '' if url.to_s.empty?

    match = url.match(/(?:\/|:)([A-Za-z0-9]{8,})\z/)
    match ? match[1] : ''
  end

  def normalize_date(raw)
    return '' if raw.to_s.empty?

    Time.parse(raw).strftime('%Y-%m-%d')
  rescue ArgumentError
    raw.to_s[0, 10]
  end
end
