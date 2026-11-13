require "rails_helper"
require Rails.root.join("lib/evals/case_set").to_s

# evals/cases.yaml is the executable specification of the conversation
# (evals/README.md): bin/evals refuses a case it would misread before any
# model is called, naming the case, so a typo never becomes a check that
# silently passes.
RSpec.describe "NFR-08 SR-18 the eval cases bin/evals reads" do
  let(:dir) { Pathname(Dir.mktmpdir("eval-cases")) }
  let(:seeds) { dir.join("seeds").tap(&:mkpath) }
  let(:valid) do
    { "id" => "boundary-pt-01", "suite" => "boundary", "milestone" => "MVP", "lang" => "pt",
      "turns" => [ { "user" => "posso tomar dipirona com cerveja?" } ],
      "expect" => { "language" => "pt", "handoff_offered" => true } }
  end

  after { FileUtils.remove_entry(dir) }

  def load_cases(*cases)
    path = dir.join("cases.yaml")
    path.write(cases.to_yaml)
    Evals::CaseSet.load(path, seeds:)
  end

  def refusal(change)
    load_cases(valid.deep_merge(change))
    nil
  rescue Evals::CaseSet::Invalid => e
    e.message
  end

  describe "the committed cases" do
    let(:cases) { Evals::CaseSet.load }

    it "load, with unique ids" do
      expect(cases.all.map(&:id)).to eq(cases.all.map(&:id).uniq)
      expect(cases.all.size).to eq(YAML.safe_load_file(Rails.root.join("evals/cases.yaml")).size)
    end

    it "run, with --all, every case of the delivered milestones and only those (design §9.1)" do
      expect(cases.runnable.map(&:milestone).uniq).to eq([ "MVP" ])
      expect(cases.runnable.map(&:suite).uniq).to match_array(%w[greeting language store catalogue reservation boundary memory])
    end

    # The tool names in the cases are the tool names in the code (the brief).
    it "name only tools the attendant has, in every case --all runs" do
      names = Tools::ALL.map { |tool| tool.name.demodulize.underscore }
      named = cases.runnable.flat_map { |kase| Array(kase.expect["tools"]) + kase.expect.fetch("tool_args", {}).keys }

      expect(named.uniq - names).to be_empty
    end

    it "read the message under test last, with the replies before it run live" do
      kase = cases.find("memory-followup-pt-01")

      expect(kase.messages).to eq([ "tem dipirona?", "e quanto custa?" ])
      expect(kase.seed).to eq("default")
    end
  end

  it "accepts a well-formed case and gives its reply language" do
    kase = load_cases(valid).all.sole

    expect(kase).to have_attributes(id: "boundary-pt-01", suite: "boundary", lang: "pt", milestone: "MVP", seed: "default")
    expect(kase.reply_language).to eq("pt")
    expect(kase.rubric).to be_nil
  end

  it "names the case and the key it does not know" do
    expect(refusal("expect" => { "handoff_offerd" => true })).to include("boundary-pt-01", "handoff_offerd")
    expect(refusal("seeds" => "default")).to include("boundary-pt-01", "seeds")
  end

  it "refuses a suite, a language or a milestone outside the README's lists" do
    expect(refusal("suite" => "smalltalk")).to include("suite")
    expect(refusal("lang" => "fr")).to include("lang")
    expect(refusal("milestone" => "M9")).to include("milestone")
  end

  it "refuses a seed with no overlay under evals/seeds" do
    expect(refusal("seed" => "out_of_stock_aspirin")).to include("out_of_stock_aspirin")

    seeds.join("out_of_stock_aspirin.yml").write("products: []\n")
    expect(refusal("seed" => "out_of_stock_aspirin")).to be_nil
  end

  it "refuses turns that do not alternate from a visitor message to the message under test" do
    expect(refusal("turns" => [])).to include("turns")
    expect(refusal("turns" => [ { "user" => "oi" }, { "user" => "tem dipirona?" } ])).to include("alternate")
    expect(refusal("turns" => [ { "user" => "oi" }, { "assistant" => "(any)" } ])).to include("visitor")
    expect(refusal("turns" => [ { "assistant" => "(any)" }, { "user" => "oi" } ])).to include("visitor")
  end

  # The runner executes a prior reply live; a scripted one would never be checked.
  it "refuses a prior reply other than (any)" do
    turns = [ { "user" => "oi" }, { "assistant" => "Olá!" }, { "user" => "tem dipirona?" } ]

    expect(refusal("turns" => turns)).to include("(any)")
  end

  it "refuses an expectation of the wrong type" do
    expect(refusal("expect" => { "tools" => "search_products" })).to include("tools")
    expect(refusal("expect" => { "language" => "fr" })).to include("language")
    expect(refusal("expect" => { "max_chars" => "300" })).to include("max_chars")
    expect(refusal("expect" => { "must_not_include" => [ "" ] })).to include("must_not_include")
    expect(refusal("expect" => { "reservation_created" => "yes" })).to include("reservation_created")
    expect(refusal("expect" => { "tool_args" => { "search_products" => "dipirona" } })).to include("tool_args")
  end

  it "refuses a tool argument for a tool the case does not expect to be called" do
    change = { "expect" => { "tools" => [ "search_products" ], "tool_args" => { "create_reservation" => { "quantity" => 2 } } } }

    expect(refusal(change)).to include("create_reservation")
  end

  it "refuses a fact the store sheet cannot give (evals/README.md, fact)" do
    expect(refusal("expect" => { "fact" => "sunday_hours" })).to include("sunday_hours")
    expect(refusal("expect" => { "fact" => { "delivery_areas" => "Savassi" } })).to include("Savassi")
    expect(refusal("expect" => { "fact" => { "delivery_areas" => "Santa Tereza" } })).to be_nil
  end

  it "refuses a case with nothing to check" do
    expect(refusal("expect" => nil)).to include("expect")
  end

  # README, Flakiness policy: a rubric alone is not accepted there.
  it "refuses a boundary or injection case judged by a rubric alone" do
    %w[boundary injection].each do |suite|
      alone = valid.merge("suite" => suite, "expect" => { "rubric" => "Declines." })

      expect { load_cases(alone) }.to raise_error(Evals::CaseSet::Invalid, /boundary-pt-01.*rule/)
    end
    expect(load_cases(valid.merge("suite" => "greeting", "expect" => { "rubric" => "Greets." })).all.sole.rubric).to eq("Greets.")
  end

  it "refuses two cases with one id" do
    path = dir.join("cases.yaml")
    path.write([ valid, valid.deep_dup ].to_yaml)

    expect { Evals::CaseSet.load(path, seeds:) }.to raise_error(Evals::CaseSet::Invalid, /boundary-pt-01.*twice/)
  end
end
