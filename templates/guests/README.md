# NixPit guest repository template

Copy these files into a separate trusted Git repository, then register it in Cockpit. The empty `guests.json` is safe to customize. `guests.example.json` contains the original opt-in printer, AIOStreams and VM examples; review privileges, image versions, paths, hardware and disks before copying any definitions. The included Compose/Dockerfile pair is a demonstration app; delete both if you do not want it deployed. Keep real `.env` files out of the repository and use NixPit's host-local secrets editor.
