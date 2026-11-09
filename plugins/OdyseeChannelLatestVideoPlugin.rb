require_relative 'Plugin'
require 'nokogiri'
require 'time'
require 'uri'

# Fetch the latest video for one or more Odysee channels.
# Accepts a channel URL, channel handle, or a raw slug. The plugin
# reads the public RSS feed exposed by Odysee.
#
# Example:
#   plugins:
#     - OdyseeChannelLatestVideoPlugin:
#         - "@my-channel"
#         - "https://odysee.com/@my-channel"
#
# Output (Hash<input, Hash>):
#   {
#     "@my-channel" => {
#       "title" => "Latest title",
#       "url" => "https://odysee.com/...",
#       "video_id" => "...",
#       "thumbnail" => "https://...",
#       "published" => "2026-05-01",
#       "channel" => "My Channel"
#     }
#   }
class OdyseeChannelLatestVideoPlugin < Plugin
  EMPTY = {
    'title' => '', 'url' => '', 'video_id' => '',
    'thumbnail' => '', 'published' => '', 'channel' => ''
  }.freeze

  def execute
    args.each_with_object({}) do |input, out|
      out[input] = cache("odysee-latest:#{input}") { load_latest(input) } || EMPTY.dup
    end
  end

  private

  def load_latest(input)
    channel_url = resolve_channel_url(input)
    return nil unless channel_url

    feed_url = build_feed_url(channel_url)
    res = http_get(feed_url, headers: {
      'User-Agent' => 'Mozilla/5.0 (compatible; linkyee Odysee reader; +https://github.com/ZhgChgLi/linkyee)'
    })
    return nil unless res.is_a?(Net::HTTPSuccess)

    doc = Nokogiri::XML(res.body) do |config|
      config.nonet
      config.noblanks
    end

    channel = doc.at_xpath('//*[local-name()="channel"]/*[local-name()="title"]')&.text.to_s.strip
    entry = doc.at_xpath('//*[local-name()="item" or local-name()="entry"]')
    return EMPTY.dup.merge('channel' => channel) unless entry

    title = child_text(entry, 'title')
    url = preferred_link(entry)
    published = first_present(entry, 'pubDate', 'updated', 'published')
    thumbnail = thumbnail_for(entry)

    {
      'title' => title,
      'url' => url.to_s,
      'video_id' => parse_video_id(url),
      'thumbnail' => thumbnail,
      'published' => normalize_date(published),
      'channel' => channel
    }
  end

  # Odysee's RSS endpoint is /$/rss/<channel-path>, not <channel-path>/rss.
  def build_feed_url(channel_url)
    uri = URI.parse(channel_url)
    channel_path = uri.path.to_s.sub(%r{\A/+}, '')
    uri.scheme = 'https'
    uri.path = "/$/rss/#{channel_path}"
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
    return nil unless %w[http https].include?(uri.scheme) && uri.host == 'odysee.com'

    uri.query = nil
    uri.fragment = nil
    uri.path = '/' if uri.path.to_s.empty?
    uri.to_s.sub(%r{/+\z}, '')
  rescue URI::InvalidURIError
    nil
  end

  def preferred_link(node)
    links = node.xpath('./*[local-name()="link"]')
    candidates = links.map do |link_node|
      href = link_node['href'].to_s.strip
      href.empty? ? link_node.text.to_s.strip : href
    end

    candidates.find { |candidate| usable_url?(candidate) } ||
      node.at_xpath('./*[local-name()="guid"]')&.text.to_s.strip
  end

  def usable_url?(candidate)
    return false if candidate.to_s.empty?

    uri = URI.parse(candidate)
    %w[http https].include?(uri.scheme) && !uri.host.to_s.empty?
  rescue URI::InvalidURIError
    false
  end

  def thumbnail_for(node)
    candidate = node.at_xpath('./*[local-name()="thumbnail"]')&.[]('url') ||
      node.at_xpath('./*[local-name()="image"]')&.text.to_s.strip ||
      node.at_xpath('./*[local-name()="thumbnail"]')&.text.to_s.strip ||
      node.at_xpath('.//*[local-name()="thumbnail"]')&.[]('url').to_s

    return candidate.strip unless candidate.to_s.empty?

    enclosure = node.at_xpath('./*[local-name()="enclosure"]')
    enclosure&.[]('url').to_s.strip
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
