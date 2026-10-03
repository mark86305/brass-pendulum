# Brass Pendulum database schema (internal name: sgpt)

Apply in this order, then run the tests in the same order:

1. SpecGPT_Schema-G1_D04_2026-09-12.sql
2. 2026_09_11_SpeculativeGPT_Schema_G2_Draft2.sql
3. SpecGPT_Schema-G3_D02_2026-09-12.sql
4. SpecGPT_Schema-G4_D01_2026-09-12.sql

Tests (expect 145 passing: 27, 33, 62, 23):

1. SpecGPT_Schema-G1_D04_Tests_2026-09-12.sql
2. 2026_09_11_SpeculativeGPT_Schema_G2_Draft2_Tests.sql
3. SpecGPT_Schema-G3_D02_Tests_2026-09-12.sql
4. SpecGPT_Schema-G4_D01_Tests_2026-09-12.sql

Tests write fixture data. Never run them against a database you want to keep.
