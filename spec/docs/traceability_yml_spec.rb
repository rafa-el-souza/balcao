require "rails_helper"

# NFR-08: the identifiers that are steps rather than tests, CI steps rather
# than examples, and measured ones are listed in docs/traceability.yml with
# one line saying where each is verified, so bin/traceability (M2-11b) can
# count them beside the suite's examples. The list is the one NFR-08's text
# names, no more and no fewer, and every file a line points at exists.
RSpec.describe "NFR-08 docs/traceability.yml" do
  let(:file) { YAML.safe_load_file(Rails.root.join("docs/traceability.yml")) }
  let(:nfr08) { Rails.root.join("docs/design.md").read[/\*\*NFR-08 Testing and CI\.\*\*(.+?)\n\n/m, 1] }

  def ids_in(text) = text.scan(/\b(?:SR|NFR|FR)-\d\d\b/).uniq.sort

  it "lists by kind exactly the identifiers NFR-08 names as steps, CI steps and measured ones" do
    steps = ids_in(nfr08[/Identifiers that are steps rather\s+than tests \((.+?)\)/m, 1])
    ci = ids_in(nfr08[/CI steps rather than\s+examples \((.+?)\)/m, 1])
    measured = ids_in(nfr08[/and measured ones \((.+?)\)/m, 1])

    expect(file.keys).to eq %w[steps ci measured]
    expect(file.transform_values { |entries| entries.keys.sort }).to eq("steps" => steps, "ci" => ci, "measured" => measured)
  end

  it "says in one line where each is verified, and every file it names exists" do
    file.each_value do |entries|
      entries.each do |id, where|
        expect(where).to be_a(String).and(match(/\S/)), id
        expect(where).not_to include("\n"), id
        where.scan(/`([^`\s]+\.(?:rb|yml|ya?ml|md|ts|json))`|`((?:bin|ops|config|docs|spec|web|\.github|\.githooks|\.kamal)\/[^`\s]+)`/).flatten.compact.each do |path|
          expect(Rails.root.join(path.sub(/#.*/, ""))).to exist, "#{id}: #{path}"
        end
      end
    end
  end

  it "names each identifier where the threat model or the design defines it" do
    defined = Rails.root.join("docs/threat-model.md").read.scan(/\*\*(SR-\d\d)\*\*/).flatten +
              Rails.root.join("docs/design.md").read.scan(/^\*\*(NFR-\d\d) /).flatten
    expect(file.values.flat_map(&:keys) - defined).to eq []
  end
end
