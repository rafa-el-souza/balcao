# A product the catalogue file no longer lists keeps its row while a
# reservation points at it (CatalogueSeed, FR-26, FR-15); `listed` false keeps
# it out of the search, so the attendant reports it as not carried rather than
# out of stock (review finding C2 of pull request #10, FR-06).
class AddListedToProducts < ActiveRecord::Migration[8.1]
  def change
    add_column :products, :listed, :boolean, null: false, default: true
  end
end
