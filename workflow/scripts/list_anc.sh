#!/bin/bash
# Alfred Script Filter — outputs ANC mode list as Alfred JSON
cat <<'EOF'
{
  "items": [
    {
      "uid": "anc-off",
      "title": "Off",
      "subtitle": "No noise control",
      "arg": "off",
      "icon": { "path": "icons/off.png" }
    },
    {
      "uid": "anc-transparency",
      "title": "Transparency",
      "subtitle": "Hear your surroundings",
      "arg": "transparency",
      "icon": { "path": "icons/transparency.png" }
    },
    {
      "uid": "anc-high",
      "title": "Noise Cancellation",
      "subtitle": "High ANC — block out the world",
      "arg": "high",
      "icon": { "path": "icons/anc.png" }
    }
  ]
}
EOF
