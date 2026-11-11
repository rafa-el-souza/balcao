# The fictional pharmacy's catalogue (design §1.2, FR-06), from
# db/seeds/catalogue.yml. Safe to run again, on a live database too: products
# are matched by sku, a second run brings price and stock back to the seed
# less what open reservations hold, and a product the file no longer lists
# leaves the catalogue (FR-15, FR-26; CatalogueSeed.seed!).
CatalogueSeed.seed!
