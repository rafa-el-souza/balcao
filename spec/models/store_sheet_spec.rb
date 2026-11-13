require "rails_helper"

RSpec.describe "FR-03 FR-26 the store fact sheet" do
  def sheet_with(changes)
    data = YAML.safe_load_file(Rails.root.join("config/store.yml"))
    changes.call(data)
    StoreSheet.new(data)
  end

  describe "config/store.yml" do
    subject(:sheet) { StoreSheet.load(Rails.root.join("config/store.yml")) }

    it "names the fictional pharmacy of design §1.2" do
      expect(sheet.identity).to include("name" => "Farmácia Vida Longa", "city" => "Belo Horizonte")
    end

    it "carries exactly the topics get_store_info answers, in the order of FR-03" do
      expect(sheet.topics.keys).to eq %w[delivery payment services contact parking]
    end

    it "opens Monday to Saturday and closes on Sunday, so a business day is a weekday or a Saturday (§1.4)" do
      travel_to Time.zone.local(2026, 11, 9, 12) do # a Monday
        week = (0..6).map { |offset| sheet.hours_on(Date.current + offset) }

        expect(week.first(6)).to all(be_a(StoreSheet::Hours))
        expect(week.last).to be_nil
      end
    end

    it "lists the week from Monday, as the system prompt shows it, with the same hours as each date" do
      monday = Date.new(2026, 11, 9)

      expect(sheet.week.map(&:first)).to eq %w[monday tuesday wednesday thursday friday saturday sunday]
      expect(sheet.week.map(&:last)).to eq((0..6).map { |offset| sheet.hours_on(monday + offset) })
    end

    it "keeps Saturday shorter than a weekday, the fact the store-hours eval reads" do
      saturday = sheet.hours_on(Date.new(2026, 11, 14))
      monday = sheet.hours_on(Date.new(2026, 11, 9))

      expect(saturday.closes).to be < monday.closes
    end

    it "lists the three in-store services of FR-08, the injection flagged for its prescription" do
      services = sheet.topic("services").fetch("list").to_h { |service| [ service["key"], service ] }

      expect(services.keys).to contain_exactly("blood_pressure", "glucose", "injection")
      expect(services.transform_values { |service| service["prescription_required"] })
        .to eq("blood_pressure" => false, "glucose" => false, "injection" => true)
    end

    it "gives the contact phone the MVP's fixed handoff line uses (FR-10 MVP note)" do
      expect(sheet.topic("contact").fetch("phone")).to match(/\A\(31\) \d{4}-\d{4}\z/)
    end

    it "answers an unknown topic with nil, so the tool can say there is no such topic" do
      expect(sheet.topic("pet_food")).to be_nil
      expect(sheet.topic(nil)).to be_nil
    end

    it "hands out frozen data, so a tool cannot change the sheet for the next turn" do
      expect(sheet.topic("delivery")).to be_frozen
      expect(sheet.topic("delivery").fetch("areas").first).to be_frozen
    end
  end

  # FR-07: "the pickup deadline (end of next business day)": the closing time
  # of the first day after the reservation's own that has hours, in São Paulo
  # (design §1.4), whatever the hour the reservation is made.
  describe "FR-07 the pickup deadline of a reservation" do
    subject(:sheet) { StoreSheet.current }

    {
      "a Thursday at noon" => [ [ 2026, 11, 12, 12, 4 ], [ 2026, 11, 13, 20, 0 ] ],
      "a Friday after closing" => [ [ 2026, 11, 13, 21, 0 ], [ 2026, 11, 14, 14, 0 ] ],
      "a Saturday, since Sunday is closed" => [ [ 2026, 11, 14, 10, 0 ], [ 2026, 11, 16, 20, 0 ] ],
      "a Sunday" => [ [ 2026, 11, 15, 10, 0 ], [ 2026, 11, 16, 20, 0 ] ],
      "a Tuesday before opening" => [ [ 2026, 11, 10, 0, 30 ], [ 2026, 11, 11, 20, 0 ] ]
    }.each do |made, (at, until_)|
      it "is the end of the next business day for a reservation made on #{made}" do
        travel_to Time.zone.local(*at) do
          expect(sheet.pickup_until(Time.current)).to eq(Time.zone.local(*until_))
        end
      end
    end

    it "reads the day in São Paulo, not in UTC, where it has already turned" do
      made = Time.utc(2026, 11, 13, 1, 30) # Thursday 22:30 in São Paulo

      expect(sheet.pickup_until(made)).to eq(Time.zone.local(2026, 11, 13, 20, 0))
    end

    it "follows the hours the file gives (FR-26)" do
      changed = sheet_with(->(data) { data["hours"]["friday"] = "closed" })

      expect(changed.pickup_until(Time.zone.local(2026, 11, 12, 12))).to eq(Time.zone.local(2026, 11, 14, 14, 0))
    end
  end

  describe "the business is one file (FR-26)" do
    it "answers with the hours of the file it was loaded from, with no code changed" do
      sheet = sheet_with(->(data) { data["hours"]["saturday"] = { "opens" => "09:00", "closes" => "13:00" } })

      expect(sheet.hours_on(Date.new(2026, 11, 14))).to eq StoreSheet::Hours.new(opens: "09:00", closes: "13:00")
    end

    it "is read once per process and kept, so the app restarts to pick up a change" do
      expect(StoreSheet.current).to be(StoreSheet.current)
    end
  end

  describe "a malformed file is refused with the key that is wrong" do
    {
      "a missing topic" => [ ->(data) { data["topics"].delete("parking") }, /topics must be exactly/ ],
      "an extra topic" => [ ->(data) { data["topics"]["pets"] = { "text" => "x" } }, /topics must be exactly/ ],
      "a missing weekday" => [ ->(data) { data["hours"].delete("monday") }, /hours must name the seven days/ ],
      "a time that is not HH:MM" => [ ->(data) { data["hours"]["saturday"]["closes"] = "2pm" }, /hours\.saturday\.closes/ ],
      "a day that closes before it opens" => [
        ->(data) { data["hours"]["monday"] = { "opens" => "20:00", "closes" => "08:00" } }, /hours\.monday/
      ],
      "a closed day spelt another way" => [ ->(data) { data["hours"]["sunday"] = "fechado" }, /hours\.sunday/ ],
      "a week without a business day, which leaves a reservation no pickup day (FR-07)" => [
        ->(data) { data["hours"].transform_values! { "closed" } }, /hours must open on at least one day/
      ],
      "a delivery fee without the currency format" => [
        ->(data) { data["topics"]["delivery"]["areas"][0]["fee"] = "7" }, /topics\.delivery\.areas\[0\]\.fee/
      ],
      "a service without a price" => [
        ->(data) { data["topics"]["services"]["list"][0].delete("price") }, /topics\.services\.list\[0\]\.price/
      ],
      "a prescription flag that is not a boolean" => [
        ->(data) { data["topics"]["services"]["list"][2]["prescription_required"] = "sim" },
        /topics\.services\.list\[2\]\.prescription_required/
      ],
      "two services with one key" => [
        ->(data) { data["topics"]["services"]["list"][1]["key"] = data["topics"]["services"]["list"][0]["key"] },
        /topics\.services\.list keys must be unique/
      ],
      "a contact without a phone" => [ ->(data) { data["topics"]["contact"].delete("phone") }, /topics\.contact\.phone/ ],
      "no pharmacy name" => [ ->(data) { data["identity"]["name"] = " " }, /identity\.name/ ]
    }.each do |label, (change, message)|
      it "refuses #{label}" do
        expect { sheet_with(change) }.to raise_error(StoreSheet::Invalid, message)
      end
    end

    it "refuses a file that is not a mapping" do
      Tempfile.create([ "store", ".yml" ]) do |file|
        file.write("- just\n- a list\n")
        file.flush

        expect { StoreSheet.load(file.path) }.to raise_error(StoreSheet::Invalid, /must be a mapping/)
      end
    end
  end
end
