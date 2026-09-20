# Be sure to restart your server when you modify this file.

# Configure parameters to be partially matched (e.g. passw matches password) and filtered from the log file.
# Use this to limit dissemination of sensitive information.
# See the ActiveSupport::ParameterFilter documentation for supported notations and behaviors.
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :crypt, :salt, :certificate, :otp, :ssn, :cvv, :cvc,
  # M5b: a private key pasted into a certificate form arrives inside the JSON
  # editor's payload; the API sends it as attributes[key] / attributes[key_alt].
  :payload_json, /(\A|\.)key(_alt)?\z/
]
