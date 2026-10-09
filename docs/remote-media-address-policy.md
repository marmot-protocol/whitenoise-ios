# Remote-media destination policy

Peer-controlled remote image URLs allow HTTPS on port 443 only. Literal hosts,
the complete DNS answer set and every redirect must pass the same non-public
address filter. The transport connects to validated numeric addresses while
retaining the original hostname for default TLS trust validation. Rejection
never falls back to an unpinned request.

The filter covers private, loopback, link-local, shared, multicast and reserved
IPv4 ranges, documentation and benchmarking blocks, deprecated relay/site-local
space, IPv6 discard/dummy prefixes, local-use NAT64 and non-global IETF protocol
allocations. Embedded IPv4 in mapped, compatible, translatable, well-known NAT64,
6to4 and Teredo forms is checked against the IPv4 policy as well.

Sources: [IANA IPv4 special-purpose registry](https://www.iana.org/assignments/iana-ipv4-special-registry/),
[IANA IPv6 special-purpose registry](https://www.iana.org/assignments/iana-ipv6-special-registry/)
and [RFC 3879](https://www.rfc-editor.org/rfc/rfc3879.html). Keep range regressions
current when allocations change. This policy preserves globally reachable IPv6
exceptions (the three `2001:1::` anycast addresses, AMT, AS112, ORCHIDv2 and DETs)
and existing public IPv4 special allocations. It deliberately retains the older
conservative block of the whole `192.0.0.0/24`, including `.9` and `.10`.

Fake-IP VPN/proxy configurations that return `198.18.0.0/15` for public CDN names
are refused too. They must supply original public destination addresses for
remote images to load. There is no synthetic-address exception or TLS downgrade.
Address filtering cannot defeat arbitrary network-specific VPN/NAT translation;
it is not a guarantee of reachability or universal isolation from local networks.

Tests inject DNS answers and redirects without contacting real private services.
They cover literal bounds, known public exceptions, IPv4 embeddings, complete
mixed-answer rejection and numeric endpoint admission. They do not substitute
for platform TLS/proxy qualification or certify native image decoders secure.
