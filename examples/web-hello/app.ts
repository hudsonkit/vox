import { createVoxdClient, type LiveSession } from "@voxd/client";

const vox = createVoxdClient({ clientId: "vox-web-hello" });
const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const status = $("status");
const text = $("text");
const start = $<HTMLButtonElement>("start");
const stop = $<HTMLButtonElement>("stop");
const file = $<HTMLInputElement>("file");

let session: LiveSession | null = null;

// probe() only checks the open /health route. capabilities() is the first
// call that needs this page's origin to be allowed.
if (await vox.probe()) {
  try {
    await vox.capabilities();
    status.textContent = "Connected to Vox on this Mac.";
    start.disabled = false;
    file.disabled = false;
  } catch {
    status.textContent = `Vox is running but does not allow ${location.origin} yet. Add it in Vox settings.`;
  }
} else {
  status.innerHTML = 'Vox is not running. <a href="https://voxd.cc/download">Get Vox</a>, then reload.';
}

// Dictation: Vox records from the Mac's microphone, so the page needs no
// microphone permission of its own.
start.onclick = async () => {
  session = vox.createLiveSession();
  session.onPartial((event) => { text.textContent = event.text; });
  session.onState((event) => { status.textContent = event.state; });
  start.disabled = true;
  stop.disabled = false;
  try {
    const final = await session.start();
    text.textContent = final.text;
  } catch (error) {
    status.textContent = String(error);
  } finally {
    session.close();
    session = null;
    start.disabled = false;
    stop.disabled = true;
  }
};

stop.onclick = () => session?.stop();

file.onchange = async () => {
  const audio = file.files?.[0];
  if (!audio) return;
  status.textContent = "Transcribing…";
  try {
    const result = await vox.transcribe({ audio });
    text.textContent = result.text;
    status.textContent = "Done.";
  } catch (error) {
    status.textContent = String(error);
  }
};
