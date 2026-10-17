switch("path", "$projectDir/../src")
switch("define", "vancodeJitNim")
# Release-mode test binaries (faster code; assertions stay on).
switch("define", "release")
switch("opt", "speed")