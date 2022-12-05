The forwarder will listen for UDP DNS requests on
one statically configured address, forward them to
another statically configured address, receive responses
and send them back to the corresponding original
requesting parties.

Main motivation was to use systemd-resolved stub listener
from Docker containers.

The forwarder can also be used for any UDP-based protocol
with the same simple request-response flow, e.g. NTP.
