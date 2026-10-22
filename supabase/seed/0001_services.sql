-- ---------------------------------------------------------------------------
-- 0001_services.sql — the canonical service catalog.
--
-- The old app stored services as a free-text array per garage, so "Oil Change"
-- and "Oil change" were different services and nothing could be filtered on.
-- This is the single list everything joins to.
-- ---------------------------------------------------------------------------

insert into public.services (slug, name, category, sort_order) values
  ('full-service',        'Full Service',         null,         10),
  ('engine-repair',       'Engine Repair',        'car',         20),
  ('oil-change',          'Oil Change',           null,         30),
  ('brake-service',       'Brake Service',        null,         40),
  ('clutch-repair',       'Clutch Repair',        'car',         50),
  ('battery-replacement', 'Battery Replacement',  null,         60),
  ('electrical-work',     'Electrical Work',      null,         70),
  ('ac-service',          'AC Service',           'car',        80),
  ('diagnostics',         'Diagnostics',          null,         90),
  ('inspection',          'Vehicle Inspection',   null,        100),
  ('wheel-alignment',     'Wheel Alignment',      null,        110),
  ('tyre-replacement',    'Tyre Replacement',     null,        120),
  ('puncture-repair',     'Puncture Repair',      null,        130),
  ('denting-painting',    'Denting & Painting',   'car',       140),
  ('body-repair',         'Body Repair',          'car',       150),
  ('two-wheeler-service', 'Two Wheeler Service',  'motorcycle',160),
  ('chain-sprocket',      'Chain & Sprocket',     'motorcycle',170),
  ('car-wash',            'Car Wash & Cleaning',  null,        180),
  ('spare-parts',         'Spare Parts',          'parts',     190),
  ('towing',              'Towing',               null,        200)
on conflict (slug) do update
  set name = excluded.name,
      category = excluded.category,
      sort_order = excluded.sort_order;
