exports.handler = async (event) => {
  // Simple router for testing
  const path = event.rawPath || "/";
  if (path === "/ping") {
    return {
      statusCode: 200,
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ ok: true, time: new Date().toISOString() }),
    };
  }
  return {
    statusCode: 200,
    headers: { "content-type": "text/plain" },
    body: "many-mailer lambda is alive",
  };
};
