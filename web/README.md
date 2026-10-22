# Web client

React and TypeScript web application for workspace administration, template editing, dashboard building and rule management.

The landing page in `src/` is a React + TypeScript conversion of `../docs/UI web/home (2).html`. It uses Tailwind CSS 4 utilities for the page layout and shared visual styles, with `styles.css` retaining theme tokens, gradients, pseudo-elements, animation and detailed device/rule demo styles. The demonstrations use local sample state only and do not send API or MQTT commands. Login and workspace links remain placeholders until the corresponding Web flows exist.

From `web/`, use `npm ci` to install the dependencies recorded in `package-lock.json`, `npm run dev` to preview, and `npm run build` to check TypeScript and create a production bundle. The dependency versions are compatibility candidates until the recorded Node/Web PoC is complete.

Web clients use the shared HTTP/WS contracts in `../contracts`; they never connect to MQTT directly or store bearer sessions in local storage.

