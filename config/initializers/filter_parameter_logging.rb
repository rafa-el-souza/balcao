# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# A visitor's message is personal data (threat model SR-30): `text` on the
# API, `body` on the WhatsApp webhook and in the database. Rails reads no JSON
# body as parameters (config/initializers/parameter_parsers.rb); these cover a
# form body and every other log of a parameter (review finding V2 of pull
# request #12).
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :text, :body
]

# A trace's token is the whole credential of a conversation's trace page
# (threat model SR-11), and parameter filtering never reaches the lines that
# carry it: Action Cable's lines, which write the stream a page follows and
# the identifier it subscribes with, and the request's own line, which writes
# the path, should a token be typed into one (the link carries it after the
# "#", and the lookup in a header). These write [FILTERED] in its place (SR-30;
# review findings C3, G1 and V3 of pull request #17). The conversations' streams name a
# conversation, which only its visitor's cookie opens, and stay as they are.
module Balcao
  module TraceTokenFilter
    PATH = %r{\A(/+(?:api/+traces|trace)/+)[^/?]+}
    STREAM = /\b(trace:)[^\s"\\)]+/
    # Escaped once in an identifier, twice when Action Cable inspects a whole
    # message it dropped (review finding C4 of pull request #23).
    PARAM = /(\\*"token\\*"\s*(?::|=>)\s*\\*")[^"\\]*/

    module_function

    def path(path) = path.sub(PATH, '\1[FILTERED]')

    def line(text) = text.gsub(STREAM, '\1[FILTERED]').gsub(PARAM, '\1[FILTERED]')
  end

  # The request's line logs the filtered path, which filters only the query.
  module FilteredTracePath
    def filtered_path = TraceTokenFilter.path(super)
  end

  # Action Cable's logger, through which every line of the cable passes. Each
  # line is cut at 2 KB once its tokens are filtered: Action Cable writes a
  # refused command whole into its line, up to the 16 KiB a message may carry
  # (threat model SR-40, ADR-0015). A message of several lines, an
  # exception's backtrace, is cut line by line, so it keeps every frame
  # (review finding N4 of pull request #23). The mark of the cut is ASCII,
  # which a line of raw bytes, as Puma hands a header over, takes too.
  class CableLogger < SimpleDelegator
    LINE = 2048

    def self.cut(text) = text.each_line.map { |line| line.chomp.truncate_bytes(LINE, omission: "...") + line[/\R\z/].to_s }.join

    %i[debug info warn error fatal unknown].each do |level|
      define_method(level) do |message = nil, &block|
        message = block.call if message.nil? && block
        message = CableLogger.cut(TraceTokenFilter.line(message)) if message.is_a?(String)
        __getobj__.public_send(level, message)
      end
    end
  end
end

ActionDispatch::Request.prepend(Balcao::FilteredTracePath)
Rails.application.config.action_cable.logger = Balcao::CableLogger.new(Rails.logger)
