its the first part of a startup idea. 

Im sadly not integrative enough to be able to directly combine myinterest in theory and art into a product.

What it is the begginings of a new type of fuzzer deployment. I realized while writing this that fuzzing infra is better suited as an appliance rather than the gigantic clusterfuzz oss fuzz bespoke infra you see in typical massive deployments. 

Typical companies are small or medium sized, have bespoke complex infra, and would pay money for better more effective triage.

So im writing a BEAM (gleam, for its typed ml like semantics, im parsing a lot of logs) triage web app (with react as the frontend) that allows folks to easily monitor a single fuzzer and run minimizers automatically in response to a crash. I realized that folks dont need the complexity of a google product, and they are prob already instrumenting fuzzers and have there own bespoke build tooling for that. I dont need source level control I Just need access to there log directory and there crash/corpus directory. Thats it.

Running my deployment would save them days too. Batching is slow and takes a long time somtimes. My product is small and focused enough to beable to run minimizers immediately and present a nice little poc in there dashboard and use github hooks to display the exact source preview that caused the crash with like mdx.
