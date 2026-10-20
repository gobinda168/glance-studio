// Prettier for the editor's Format Document: the standalone build and the plugins for the languages it formats.
import * as prettier from "prettier/standalone";
import * as babel from "prettier/plugins/babel";
import * as estree from "prettier/plugins/estree";
import * as typescript from "prettier/plugins/typescript";
import * as postcss from "prettier/plugins/postcss";
import * as html from "prettier/plugins/html";
import * as markdown from "prettier/plugins/markdown";
import * as yaml from "prettier/plugins/yaml";
import * as graphql from "prettier/plugins/graphql";

window.glancePrettier = { prettier, plugins: [babel, estree, typescript, postcss, html, markdown, yaml, graphql] };
