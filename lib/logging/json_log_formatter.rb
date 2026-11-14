require "json"
require "logger"
require "active_support/tagged_logging"

module Balcao
  # NFR-05: in production every log line is one JSON object: the time in UTC,
  # the level, the message, and the tags of the lines Rails tags. A tag of the
  # form name=value becomes a field (the request's id, config/environments/
  # production.rb; a turn's conversation, ProcessTurnJob), any other stays in
  # a list (Active Job's "ActiveJob", the job's class and id). A message of
  # several lines, a backtrace's, stays one line of the log, and bytes that
  # are not UTF-8 are replaced, never raised on: a log line fails no caller.
  #
  # Masking is the sources' (threat model SR-30): parameter filtering, the
  # error lines of config/initializers/log_masking.rb, and the app's own
  # lines, which name an error by its class. An error logged as an object is
  # written here by its class alone too.
  class JsonLogFormatter < ::Logger::Formatter
    # Rails' tagged logging, included rather than extended: this call, not
    # its own, writes the line, and reads the tags itself.
    include ActiveSupport::TaggedLogging::Formatter

    FIELD = /\A([a-z][a-z_]*)=(.+)\z/

    def call(severity, time, _progname, message)
      entry = { "time" => time.utc.iso8601(3), "level" => severity }
      tags = []
      current_tags.each do |tag|
        name, value = tag.to_s.match(FIELD)&.captures
        name ? entry[name] = value : tags << text(tag.to_s)
      end
      entry["tags"] = tags if tags.any?
      entry["message"] = message_of(message)
      "#{JSON.generate(entry)}\n"
    end

    # Rails joins the lines of a request's error with the tags' text
    # (ActionDispatch::DebugExceptions#log_array); here the tags are fields.
    def tags_text = ""

    private

    def message_of(message)
      case message
      when String then text(message)
      when Exception then message.class.name
      when nil then ""
      else text(message.inspect)
      end
    end

    def text(value)
      value = value.dup.force_encoding(Encoding::UTF_8) unless value.encoding == Encoding::UTF_8
      value.valid_encoding? ? value : value.scrub
    end
  end
end
