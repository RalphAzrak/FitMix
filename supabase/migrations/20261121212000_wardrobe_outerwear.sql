-- Jackets and hoodies share a slot. Existing Wardrobe categories remain valid.
alter table public.wardrobe_items
    drop constraint wardrobe_items_category_check,
    add constraint wardrobe_items_category_check
        check (category in ('tshirt', 'pants', 'shoes', 'accessory', 'outerwear'));
