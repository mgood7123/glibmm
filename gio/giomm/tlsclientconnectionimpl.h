#ifndef _GIOMM_TLSCLIENTCONNECTIONIMPL_H
#define _GIOMM_TLSCLIENTCONNECTIONIMPL_H

/* Copyright (C) 2020 The giomm Development Team
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <giommconfig.h>
#include <giomm/tlsclientconnection.h>
#include <giomm/tlsconnection.h>

namespace Gio
{

/** %Gio::TlsClientConnectionImpl implements the Gio::TlsClientConnection interface.
 *
 * The GTlsClientConnection interface can be implemented by C classes that
 * derive from GTlsConnection. No public GLib class implements GTlsClientConnection.
 * Some GLib functions, such as g_tls_client_connection_new(), return an object
 * of a class which is derived from GTlsConnection and implements GTlsClientConnection.
 * Since that C class is not public, it's not wrapped in a C++ class.
 * A C object of such a class can be wrapped in a %Gio::TlsClientConnectionImpl object.
 * %Gio::TlsClientConnectionImpl does not directly correspond to any GLib class.
 *
 * This class is intended only for wrapping C objects returned from GLib functions.
 *
 * @newin{2,66}
 */
class GIOMM_API TlsClientConnectionImpl : public TlsClientConnection, public TlsConnection
{
public:
  explicit TlsClientConnectionImpl(GTlsConnection* castitem);
};

} // namespace Gio

namespace Glib
{
  /** A %Glib::wrap() method for this object.
   *
   * It's not called %wrap() because it wraps a C object which is derived from
   * GTlsConnection and implements the GTlsClientConnection interface.
   *
   * @param object The C instance.
   * @param take_copy False if the result should take ownership of the C instance.
   *                  True if it should take a new ref.
   * @result A C++ instance that wraps this C instance.
   *
   * @relates Gio::TlsClientConnectionImpl
   */
  GIOMM_API
  Glib::RefPtr<Gio::TlsClientConnectionImpl> wrap_tls_client_connection_impl(
    GTlsConnection* object, bool take_copy = false);

} // namespace Glib

#endif /* _GIOMM_TLSCLIENTCONNECTIONIMPL_H */
