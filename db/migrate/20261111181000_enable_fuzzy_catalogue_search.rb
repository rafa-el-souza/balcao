# Levenshtein distance for the catalogue search (FR-06): a typo that swaps two
# letters ("dipriona") breaks too many trigrams for pg_trgm, and the edit
# distance between the stems still finds it (review finding C3 of pull request
# #10). Ships with PostgreSQL as a trusted extension, like pg_trgm.
class EnableFuzzyCatalogueSearch < ActiveRecord::Migration[8.1]
  def change
    enable_extension "fuzzystrmatch"
  end
end
