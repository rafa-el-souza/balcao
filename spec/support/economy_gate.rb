# ADR-0003's gate: the economy model serves only on the full eval run's word,
# evals/economy_allowed.yml, which the app reads at boot
# (config/initializers/budget.rb). No example depends on what the committed
# file says: each starts with the gate closed, and one that needs the economy
# model to serve opens it.
RSpec.configure do |config|
  config.before do
    Rails.configuration.x.economy_allowed = false
    # The months whose forced economy this process already said pauses the
    # demo (Budget.line), and the operator's alerts it knows are written or
    # already said it could not write (Budget.alert): none, for each example.
    Budget.instance_variable_set(:@held, nil)
    Budget.instance_variable_set(:@alerted, nil)
    Budget.instance_variable_set(:@unwritten, nil)
  end
end
