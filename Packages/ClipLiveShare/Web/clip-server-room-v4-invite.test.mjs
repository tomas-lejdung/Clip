import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";

import { openClipServerRoomV4Invite } from "./clip-server-room-v4-invite.mjs";

const fixture = JSON.parse(
  await readFile(
    new URL("../Tests/Fixtures/server-room-v4-invite.json", import.meta.url),
    "utf8",
  ),
);

test("browser parser opens the canonical Swift v4 invite", async () => {
  const invite = await openClipServerRoomV4Invite(fixture.url);
  assert.deepEqual(
    {
      version: invite.version,
      serviceEndpoint: invite.serviceEndpoint,
      serviceRoomURL: invite.serviceRoomURL,
      roomCode: invite.roomCode,
      roomId: invite.roomId,
      sessionId: invite.sessionId,
      admissionCapability: invite.admissionCapability,
      roomAgreementSecret: invite.roomAgreementSecret,
    },
    {
      version: 4,
      serviceEndpoint: "https://mesh.clip.example",
      serviceRoomURL: "https://mesh.clip.example/MESH4APP",
      roomCode: fixture.roomCode,
      roomId: fixture.roomId,
      sessionId: fixture.sessionId,
      admissionCapability: fixture.admissionCapability,
      roomAgreementSecret: fixture.roomAgreementSecret,
    },
  );
});

test("browser parser requires TLS except on exact loopback HTTP hosts", async () => {
  for (const host of ["localhost:8080", "127.0.0.1:8080", "[::1]:8080"]) {
    const loopback = new URL(fixture.url);
    loopback.protocol = "http:";
    loopback.host = host;
    assert.equal(
      (await openClipServerRoomV4Invite(loopback)).roomId,
      fixture.roomId,
    );
  }

  for (const host of [
    "mesh.clip.example",
    "localhost.example.com",
    "dev.localhost",
    "localhost.",
    "127.0.0.2",
    "[::2]",
  ]) {
    const insecure = new URL(fixture.url);
    insecure.protocol = "http:";
    insecure.host = `${host}:8080`;
    await assert.rejects(
      openClipServerRoomV4Invite(insecure),
      /Invalid Clip room service URL/u,
    );
  }
});

test("browser parser binds ciphertext to the human room code", async () => {
  const invite = new URL(fixture.url);
  invite.pathname = "/MESH4APQ";
  await assert.rejects(openClipServerRoomV4Invite(invite));
});

test("browser parser rejects changed capabilities and noncanonical grammar", async () => {
  const changedCapability = new URL(fixture.url);
  changedCapability.hash = changedCapability.hash.replace(/join=./, "join=A");
  await assert.rejects(openClipServerRoomV4Invite(changedCapability));

  const reordered = new URL(fixture.url);
  const [version, key, join] = reordered.hash.slice(1).split("&");
  reordered.hash = `${version}&${join}&${key}`;
  await assert.rejects(openClipServerRoomV4Invite(reordered));

  const queried = new URL(fixture.url);
  queried.search = "?room=leak";
  await assert.rejects(openClipServerRoomV4Invite(queried));

  const extra = new URL(fixture.url);
  extra.hash += "&unknown=1";
  await assert.rejects(openClipServerRoomV4Invite(extra));
});
