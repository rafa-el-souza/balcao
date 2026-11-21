# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
#
# A visitor's message is personal data (threat model SR-30): `text` on the
# API, `body` in the database, and a Telegram update's message as a whole (its
# text, its caption, its sender, its chat and whatever else was sent, under
# "message", "edited_message" and the other kinds that end in it), so an
# update is logged as its update_id alone. Rails reads no JSON body as
# parameters (config/initializers/parameter_parsers.rb); these cover a form
# body and every other log of a parameter (review finding V2 of pull request
# #12). The bot's token, which every Bot API URL carries, is a `token`.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  :text, :body, :message, :caption, :phone
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
  # message is cut at 2 KB once its tokens are filtered: Action Cable writes a
  # refused command whole into its line, up to the 16 KiB a message may carry,
  # line breaks a client put in it included (threat model SR-40, ADR-0015;
  # review finding R1 of pull request #23). A backtrace, which Action Cable
  # logs as a message of its own, a frame a line, is cut line by line, so it
  # keeps every frame (N4); no message carrying a client's text starts like a
  # frame, since Action Cable writes its own words first. The mark of the cut
  # is ASCII, which a line of raw bytes, as Puma hands a header over, takes
  # too.
  #
  # A message that is not a backtrace is written on one line: its control
  # characters, a client's line breaks among them, are escaped ("\x0A"), so
  # no client's text starts a line that could pass for one of the app's
  # (review finding V7 of pull request #23).
  class CableLogger < SimpleDelegator
    LINE = 2048
    FRAME = /\A\S+:\d+:in / # Ruby's "path:line:in 'method'"
    CONTROL = /[\x00-\x08\x0A-\x1F\x7F]/
    # Action Cable's own error lines write the error's message: a worker's
    # "There was an exception - Class(message)" and a command's "Could not
    # execute command from (...) [Class - message]: frames". A message may
    # quote a row the database refused, so only the class stays, as in Rails'
    # own error lines (threat model SR-30; review finding X1 of pull request
    # #42, M3's sweep). A client writes the command, so the mask starts at the
    # first place in it that looks like the error's part, keeping more of the
    # line out rather than less; the frames after the last "]: " stay.
    WORKER_ERROR = /\A(There was an exception - \S+?)\(.*\)\z/m
    COMMAND_ERROR = /\A(Could not execute command from \(.*?\) \[[^\s\[\]]+) - .*(\]: (?:(?!\]: ).)*)\z/m

    def self.masked(text) = text.sub(WORKER_ERROR, '\1([FILTERED])').sub(COMMAND_ERROR, '\1 - [FILTERED]\2')

    def self.cut(text)
      unless text.match?(FRAME)
        return text.gsub(CONTROL) { |character| format("\\x%02X", character.ord) }.truncate_bytes(LINE, omission: "...")
      end

      text.each_line.map { |line| line.chomp.truncate_bytes(LINE, omission: "...") + line[/\R\z/].to_s }.join
    end

    %i[debug info warn error fatal unknown].each do |level|
      define_method(level) do |message = nil, &block|
        message = block.call if message.nil? && block
        message = CableLogger.cut(TraceTokenFilter.line(CableLogger.masked(message))) if message.is_a?(String)
        __getobj__.public_send(level, message)
      end
    end
  end
end

ActionDispatch::Request.prepend(Balcao::FilteredTracePath)
Rails.application.config.action_cable.logger = Balcao::CableLogger.new(Rails.logger)
