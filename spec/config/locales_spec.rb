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
