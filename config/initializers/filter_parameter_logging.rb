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
