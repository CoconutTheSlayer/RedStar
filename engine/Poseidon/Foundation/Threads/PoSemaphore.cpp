#include <Poseidon/Foundation/Threads/PoSemaphore.hpp>

namespace Poseidon::Foundation
{
PoSemaphore::PoSemaphore(long init, long maxCount)
{
    LockRegister(lock, "PoSemaphore");
    if (init < 0L)
    {
        init = 0L;
    }
#ifdef _WIN32
    handle = CreateSemaphore(nullptr, init, maxCount, nullptr);
    error = (handle == nullptr);
#elif defined(__APPLE__)
    _count = init;
    bool ok = (pthread_mutex_init(&_mtx, nullptr) == 0) && (pthread_cond_init(&_cv, nullptr) == 0);
    error = !ok;
    // maxCount is ignored, matching the pthreads path
#else
    error = (sem_init(&sem, 0, (unsigned)init) != 0);
    // maxCount is ignored under pthreads
#endif
}

void PoSemaphore::wait()
{
#ifdef _WIN32
    if (handle != nullptr)
    {
        WaitForSingleObject(handle, INFINITE);
    }
#elif defined(__APPLE__)
    pthread_mutex_lock(&_mtx);
    while (_count <= 0L)
    {
        pthread_cond_wait(&_cv, &_mtx);
    }
    _count--;
    pthread_mutex_unlock(&_mtx);
#else
    sem_wait(&sem);
#endif
}

bool PoSemaphore::tryWait()
{
#ifdef _WIN32
    if (handle == nullptr)
    {
        return false;
    }
    return (WaitForSingleObject(handle, 0L) == WAIT_OBJECT_0);
#elif defined(__APPLE__)
    pthread_mutex_lock(&_mtx);
    bool acquired = (_count > 0L);
    if (acquired)
    {
        _count--;
    }
    pthread_mutex_unlock(&_mtx);
    return acquired;
#else
    return (sem_trywait(&sem) == 0);
#endif
}

void PoSemaphore::signal(long count)
{
    if (count < 1L)
    {
        count = 1L;
    }
#ifdef _WIN32
    if (handle == nullptr)
    {
        error = true;
        return;
    }
    // NOTE: ReleaseSemaphore returns nonzero on success — this error test reads inverted.
    error = (ReleaseSemaphore(handle, count, nullptr) != 0);
#elif defined(__APPLE__)
    pthread_mutex_lock(&_mtx);
    _count += count;
    pthread_cond_broadcast(&_cv); // waiters re-check _count under the while loop
    pthread_mutex_unlock(&_mtx);
    error = false;
#else
    error = false;
    while (!error && count > 0L)
    {
        error = (sem_post(&sem) != 0);
        count--;
    }
#endif
}

long PoSemaphore::getValue()
{
#ifdef _WIN32
    error = true; // getValue is not available on Win32
    return 0L;
#else
#ifdef __CYGWIN__
    error = true;
    return 0L;
#elif defined(__APPLE__)
    pthread_mutex_lock(&_mtx);
    long val = _count;
    pthread_mutex_unlock(&_mtx);
    error = false;
    return val;
#else
    int val = 0;
    error = (sem_getvalue(&sem, &val) != 0);
    return (long)val;
#endif
#endif
}

PoSemaphore::~PoSemaphore()
{
#ifdef _WIN32
    if (handle != nullptr)
    {
        CloseHandle(handle);
        handle = nullptr;
    }
#elif defined(__APPLE__)
    pthread_cond_destroy(&_cv);
    pthread_mutex_destroy(&_mtx);
#else
    sem_destroy(&sem);
#endif
}

} // namespace Poseidon::Foundation
