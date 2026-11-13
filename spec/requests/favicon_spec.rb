require "rails_helper"

# The tab's icon for whatever asks the site's root for it without reading a
# page: a browser that shows no SVG icon (Safari before 26), a response that
# names no icon (the health check, a JSON answer opened in a tab), a crawler.
# Before this file every such request was a 404 (design §6.7, note of
# 2026-11-13 in §10).
RSpec.describe "Design §6.7 the tab's icon at the site's root", type: :request do
  it "serves /favicon.ico, the cross on its paper at 16 and 32 px" do
    get "/favicon.ico"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq "image/vnd.microsoft.icon"
    reserved, type, count = response.body.unpack("v3")
    expect([ reserved, type, count ]).to eq [ 0, 1, 2 ]
    widths = response.body.unpack("@6C@22C")
    expect(widths).to eq [ 16, 32 ]
  end

  # public/ is cached for a year, so the page's link asks for the .ico by its
  # content (web/index.html, review finding C1 of pull request #22); the
  # query only names the version, and the file is the same.
  it "sends the same file for the version the page's link names" do
    get "/favicon.ico?v=ada79c53"

    expect(response).to have_http_status(:ok)
    expect(response.body).to eq File.binread(Rails.public_path.join("favicon.ico"))
  end
end
