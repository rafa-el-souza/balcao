require "rails_helper"

RSpec.describe "NFR-09 server locales" do
  it "offers exactly pt-BR, en and es, with pt-BR as the default" do
    expect(I18n.available_locales).to contain_exactly(:"pt-BR", :en, :es)
    expect(I18n.default_locale).to eq(:"pt-BR")
  end

  it "translates a key in each of the three locales" do
    %i[pt-BR en es].each do |locale|
      expect(I18n.t("app.name", locale: locale)).to eq("Balcão")
    end
  end
end

RSpec.describe "NFR-09 Rails' own messages and formats in the three locales" do
  let(:probe_class) do
    Class.new do
      include ActiveModel::Model

      def self.name = "Probe"

      attr_accessor :name

      validates :name, presence: true
    end
  end

  {
    "pt-BR": [ "não pode ficar em branco", "09/11/2026" ],
    en: [ "can't be blank", "2026-11-09" ],
    es: [ "no puede estar en blanco", "9/11/2026" ]
  }.each do |locale, (blank, date)|
    it "renders a validation message and a date in #{locale}" do
      I18n.with_locale(locale) do
        probe = probe_class.new
        probe.validate

        expect(probe.errors[:name]).to eq([ blank ])
        expect(I18n.l(Date.new(2026, 11, 9))).to eq(date)
      end
    end
  end

  it "loads no locale outside the three" do
    expect(I18n.backend.available_locales).to all(satisfy { |locale| %i[pt-BR en es].include?(locale) })
  end
end
