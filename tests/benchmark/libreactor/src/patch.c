
int reactor_core_construct2(int num_threads)
{
  int e;

  core = (struct reactor_core) {0};
  core.fd = epoll_create1(EPOLL_CLOEXEC);
  if (core.fd == -1)
    return REACTOR_ERROR;

  e = reactor_pool_construct(&core.pool);
  if (e == -1)
    {
      (void) close(core.fd);
      core.fd = -1;
      return REACTOR_ERROR;
    }
  
  reactor_pool_limits(&core.pool, 1, num_threads);
  return REACTOR_OK;
}

/* cat ../src/patch.c >> src/reactor/reactor_core.c */
