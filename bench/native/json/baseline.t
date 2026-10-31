The hand-written pre-shapes decoder and encoder keep the baseline corpus
byte for byte. The corpus exercises opaque IDs and Money, Time, an array,
a record, a sum and both Option cases.

  $ ren run smoke.ren
  22188

  $ ren build smoke.ren --release -o small
  $ ./small
  22188
