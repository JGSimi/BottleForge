import fs from "node:fs";
import { Laya } from "@receptron/laya";

const input = JSON.parse(fs.readFileSync(0, "utf8"));
const cacheDir = process.env.LAYA_CACHE;

const criteria = {
  dxmt_standard:
    "DXMT/Metal with MSync disabled. Stable baseline with minimal synchronization changes.",
  dxmt_msync:
    "DXMT/Metal with MSync enabled. Prefer when reduced Wine synchronization overhead may improve frame pacing.",
  dxmt_force_d3d11:
    "DXMT/Metal with MSync disabled and -force-d3d11. Useful for Unity games that may select another graphics API.",
  dxmt_msync_force_d3d11:
    "DXMT/Metal with MSync enabled and -force-d3d11. Combines synchronization optimization with explicit D3D11."
};

const laya = await Laya.load({
  cacheDir,
  onProgress: ({ file, received, total }) => {
    process.stderr.write(
      JSON.stringify({ type: "progress", file, received, total }) + "\n"
    );
  }
});
const result = await laya.systemOne(input.state, {
  profile: {
    type: "choice",
    instructions:
      "Choose the launch profile most likely to maximize stable frame rate and frame pacing while preserving game stability on this Apple Silicon Mac.",
    criteria
  }
});

const answer = result.answers.profile;
process.stdout.write(
  JSON.stringify({
    profile: answer.choice,
    probabilities: answer.probabilities,
    confidence: answer.confidence ?? null,
    inputTokens: result.usage?.input_tokens ?? null
  })
);

await laya.close();
