require "rails_helper"

# The landing's chips and the chat's first visit show each opener's text and
# send only its key (FR-21); the server sends the text its own file names for
# that key, and nothing for any other (threat model SR-34). The web app keeps
# a copy of the file's keys and texts to render them before any request
# (web/src/openers.json, NFR-10), so the two are held in step here: a chip
# that showed one sentence and sent another would mislead the visitor.
RSpec.describe "FR-21 the web app's openers are the server's" do
  let(:web) { JSON.parse(Rails.root.join("web/src/openers.json").read) }

  it "has every key of config/openers.yml, in the file's order, and no other" do
    expect(web.keys).to eq Openers.current.keys
  end

  it "shows each key's text in the key's language" do
    Openers.current.keys.each do |key|
      opener = Openers.current.fetch(key)
      expect(web.fetch(key)).to eq("lang" => opener.lang, "text" => opener.text)
    end
  end
end
