class ApplicationController < ActionController::API
  # skip_parameter_encoding, which the API-only base leaves out: the trace's
  # actions take a token of any bytes and answer a miss (review finding S5 of
  # pull request #17). The module sets each controller up as it is defined.
  include ActionController::ParameterEncoding
end
