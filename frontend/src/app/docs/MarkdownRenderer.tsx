"use client";

import { ReactNode } from "react";

/**
 * Minimal markdown-to-JSX renderer.
 * Handles: headings, code blocks, tables, bold, lists, paragraphs.
 * Intentionally lightweight — no external deps.
 */
function renderInline(text: string): ReactNode[] {
  const nodes: ReactNode[] = [];
  // Bold: **text**
  const parts = text.split(/(\*\*[^*]+\*\*)/g);
  parts.forEach((part, i) => {
    if (part.startsWith("**") && part.endsWith("**")) {
      nodes.push(<strong key={i}>{part.slice(2, -2)}</strong>);
    } else {
      // Inline code: `text`
      const codeParts = part.split(/(`[^`]+`)/g);
      codeParts.forEach((cp, j) => {
        if (cp.startsWith("`") && cp.endsWith("`")) {
          nodes.push(
            <code key={`${i}-${j}`} className="px-1.5 py-0.5 rounded bg-slate-800 text-cyan-300 text-sm font-mono">
              {cp.slice(1, -1)}
            </code>
          );
        } else {
          nodes.push(<span key={`${i}-${j}`}>{cp}</span>);
        }
      });
    }
  });
  return nodes;
}

export function MarkdownRenderer({ content }: { content: string }) {
  const lines = content.split("\n");
  const elements: ReactNode[] = [];
  let i = 0;
  let key = 0;

  while (i < lines.length) {
    const line = lines[i];

    // Code block
    if (line.trim().startsWith("```")) {
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !lines[i].trim().startsWith("```")) {
        codeLines.push(lines[i]);
        i++;
      }
      i++; // skip closing ```
      elements.push(
        <pre key={key++} className="my-4 p-4 rounded-lg bg-slate-900 border border-slate-700 overflow-x-auto">
          <code className="text-sm font-mono text-slate-300 whitespace-pre">{codeLines.join("\n")}</code>
        </pre>
      );
      continue;
    }

    // Table
    if (line.includes("|") && i + 1 < lines.length && lines[i + 1].includes("---")) {
      const tableLines: string[] = [];
      while (i < lines.length && lines[i].includes("|")) {
        tableLines.push(lines[i]);
        i++;
      }
      const rows = tableLines.map((tl) =>
        tl.split("|").map((c) => c.trim()).filter((_, idx, arr) => idx > 0 && idx < arr.length - 1)
      );
      // Skip separator row
      const header = rows[0] || [];
      const body = rows.slice(2).filter((r) => r.length > 0);
      elements.push(
        <div key={key++} className="my-4 overflow-x-auto">
          <table className="w-full border-collapse text-sm">
            <thead>
              <tr className="border-b border-slate-600">
                {header.map((h, hi) => (
                  <th key={hi} className="px-3 py-2 text-left text-cyan-300 font-semibold">{renderInline(h)}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {body.map((row, ri) => (
                <tr key={ri} className="border-b border-slate-800">
                  {row.map((cell, ci) => (
                    <td key={ci} className="px-3 py-2 text-slate-300">{renderInline(cell)}</td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      );
      continue;
    }

    // Headings
    if (line.startsWith("### ")) {
      elements.push(<h3 key={key++} className="text-lg font-semibold text-white mt-6 mb-2">{renderInline(line.slice(4))}</h3>);
      i++; continue;
    }
    if (line.startsWith("## ")) {
      elements.push(<h2 key={key++} className="text-xl font-bold text-white mt-8 mb-3">{renderInline(line.slice(3))}</h2>);
      i++; continue;
    }
    if (line.startsWith("# ")) {
      elements.push(<h1 key={key++} className="text-2xl font-bold text-cyan-300 mt-8 mb-4">{renderInline(line.slice(2))}</h1>);
      i++; continue;
    }

    // List items
    if (line.match(/^\s*[-*] /)) {
      const listItems: string[] = [];
      while (i < lines.length && lines[i].match(/^\s*[-*] /)) {
        listItems.push(lines[i].replace(/^\s*[-*] /, ""));
        i++;
      }
      elements.push(
        <ul key={key++} className="my-3 space-y-1 list-disc list-inside text-slate-300">
          {listItems.map((item, li) => <li key={li}>{renderInline(item)}</li>)}
        </ul>
      );
      continue;
    }

    // Empty line
    if (line.trim() === "") { i++; continue; }

    // Paragraph
    elements.push(<p key={key++} className="my-2 text-slate-300 leading-relaxed">{renderInline(line)}</p>);
    i++;
  }

  return <div className="max-w-4xl mx-auto">{elements}</div>;
}
