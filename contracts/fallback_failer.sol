contract FallbackFailer {
  function () {
    throw;
  }
}
