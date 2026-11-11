# Rails reads no JSON body as parameters (threat model SR-30, SR-04; review
# finding C3 of pull request #12). Its controller instrumentation logs the
# request's parameters before the action runs, which would put a visitor's
# message in the log, where neither the deletion (FR-05) nor the seven-day
# purge reaches it, and would parse a body before the API's checks. Each
# endpoint that takes JSON reads its own body, after those checks
# (Api::BaseController#json_body); the WhatsApp webhook (PR-18) checks its
# signature on the raw body anyway.
ActionDispatch::Request.parameter_parsers = ActionDispatch::Request.parameter_parsers.except(:json)
