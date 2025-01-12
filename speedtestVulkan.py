import os
import platform
import matplotlib.pyplot as plt
import numpy as np
from subprocess import Popen, PIPE

if platform.system() == "Windows":
    os.chdir("PrivacyAmplification/bin/Release/")
else:
    os.chdir("PrivacyAmplification/")

d = np.zeros(shape=(2,28,10))
process = Popen(["./PrivacyAmplification", "speedtest"], stdout=PIPE, universal_newlines=True)
(output, err) = process.communicate()
exit_code = process.wait()
exec(output)

fig, ax = plt.subplots()
ax.plot(range(11, 28), d[0, 11:], 'o')
ax.set(xlabel='log2(Blocksize[bit])', ylabel='Speed [Mbit/s]',
       title='Privacy Ampification Vulkan - RTX 3080 - dynamic Toeplitz seed')
ax.grid()
fig.savefig("PrivacyAmpification_RTX_3080_dynamic_seed.svg", format='svg', dpi=1200)

fig, ax = plt.subplots()
ax.plot(range(11, 28), d[1, 11:], 'o')
ax.set(xlabel='log2(Blocksize[bit])', ylabel='Speed [Mbit/s]',
       title='Privacy Ampification Vulkan - RTX 3080 - static Toeplitz seed')
ax.grid()
fig.savefig("PrivacyAmpification_RTX_3080_static_seed.svg", format='svg', dpi=1200)
